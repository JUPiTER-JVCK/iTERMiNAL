import Foundation

/// A run of the file held in memory, every read of which is checked.
///
/// A parser reads a header, or a packet, or a chunk's first bytes through one of
/// these, and nothing it is told by the file can make it read outside it: a read
/// that does not fit is `nil`, not a trap. That matters more than anything else in
/// a parser, because the files it is given are the ones that lie.
struct ByteWindow {
    /// The most `init(source:at:count:)` will hold.
    static let maxBytes = 4 * 1024 * 1024

    /// Where in the file `bytes` starts. Every offset a window takes is a file offset.
    let base: Int64
    let bytes: [UInt8]

    init(base: Int64, bytes: [UInt8]) {
        self.base = base
        self.bytes = bytes
    }

    /// Up to `count` bytes of `source` from `offset`: fewer at the end of it.
    init(source: ByteSource, at offset: Int64, count: Int) {
        let wanted = Int64(max(0, min(count, ByteWindow.maxBytes)))
        let start = max(0, offset)
        let end = start > Int64.max - wanted ? Int64.max : start + wanted
        self.init(base: start, bytes: source.read(start..<end))
    }

    /// One past the last byte held.
    var end: Int64 { base + Int64(bytes.count) }

    /// Whether `count` bytes from `offset` are all held.
    func has(_ offset: Int64, _ count: Int) -> Bool {
        count >= 0 && offset >= base && offset - base <= Int64(bytes.count) - Int64(count)
    }

    func u8(_ offset: Int64) -> UInt8? {
        has(offset, 1) ? bytes[Int(offset - base)] : nil
    }

    /// An unsigned number of `size` bytes, 1 to 8.
    func uint(_ offset: Int64, size: Int, _ endianness: Endianness) -> UInt64? {
        guard size >= 1, size <= 8, has(offset, size) else { return nil }
        let start = Int(offset - base)
        var value: UInt64 = 0
        switch endianness {
        case .big:
            for i in 0..<size { value = (value << 8) | UInt64(bytes[start + i]) }
        case .little:
            for i in stride(from: size - 1, through: 0, by: -1) { value = (value << 8) | UInt64(bytes[start + i]) }
        }
        return value
    }

    func u16(_ offset: Int64, _ endianness: Endianness) -> UInt16? {
        uint(offset, size: 2, endianness).map { UInt16($0) }
    }

    func u32(_ offset: Int64, _ endianness: Endianness) -> UInt32? {
        uint(offset, size: 4, endianness).map { UInt32($0) }
    }

    func u64(_ offset: Int64, _ endianness: Endianness) -> UInt64? {
        uint(offset, size: 8, endianness)
    }

    /// `count` bytes from `offset`, if all held.
    func slice(_ offset: Int64, _ count: Int) -> ArraySlice<UInt8>? {
        guard has(offset, count) else { return nil }
        let start = Int(offset - base)
        return bytes[start..<(start + count)]
    }
}

/// How a field's bytes are put into words.
enum FieldText {
    /// "48 65 6C 6C 6F" and, past `limit` bytes, an ellipsis.
    static func hex(_ bytes: ArraySlice<UInt8>, limit: Int = 16) -> String {
        var text = bytes.prefix(limit).map { ByteRadix.hex.cell($0) }.joined(separator: " ")
        if bytes.count > limit { text += " …" }
        return text
    }

    /// The bytes as text, a dot for what is not printable, quoted.
    static func ascii(_ bytes: ArraySlice<UInt8>, limit: Int = 48) -> String {
        var text = String(decoding: bytes.prefix(limit).map(HexGeometry.textByte), as: UTF8.self)
        if bytes.count > limit { text += "…" }
        return "\"" + text + "\""
    }

    /// 4660 as "4660 (0x1234)", and a small number as itself.
    static func number(_ value: UInt64, size: Int) -> String {
        guard value >= 10 else { return "\(value)" }
        let digits = String(value, radix: 16, uppercase: true)
        let padded = String(repeating: "0", count: max(0, size * 2 - digits.count)) + digits
        return "\(value) (0x\(padded))"
    }

    /// "0x1234": a hex number as it is written in a spec.
    static func hexNumber(_ value: UInt64, size: Int) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return "0x" + String(repeating: "0", count: max(0, size * 2 - digits.count)) + digits
    }

    static func bytes(_ count: Int64) -> String {
        count == 1 ? "1 byte" : "\(count) bytes"
    }
}

/// The fields of one structure, in file order, added as they are read.
///
/// A parser says what it expects to find — "a 16-bit port at offset 34" — and gets back
/// the number, or nil if the bytes are not there. If they are not there the field is
/// recorded as cut off, and the rest of the list does nothing, so a short file gives
/// one honest "the data ends here" and not a cascade.
///
/// With `recording` off the numbers still come back but no nodes are made, for when
/// all that is wanted is what a packet says about itself.
struct FieldList {
    let idPrefix: String
    let window: ByteWindow
    var endianness: Endianness
    let recording: Bool

    private(set) var nodes: [FieldNode] = []
    /// Set once a field did not fit in the window.
    private(set) var truncated = false
    private var used: [String: Int] = [:]

    /// Set by the builder of a group, once its fields are known, to give the group a
    /// value or a note of its own: "10.0.0.1 → 8.8.8.8".
    var groupValue: String?
    var groupNote: String?

    init(idPrefix: String, window: ByteWindow, endianness: Endianness = .big, recording: Bool = true) {
        self.idPrefix = idPrefix
        self.window = window
        self.endianness = endianness
        self.recording = recording
    }

    // MARK: Fields

    /// A number of `size` bytes. `value` and `note` say it in words; without `value`
    /// it is shown in decimal and hex.
    @discardableResult
    mutating func uint(_ name: String, at offset: Int64, size: Int, kind: FieldNode.Kind = .integer,
                       value: ((UInt64) -> String)? = nil, note: ((UInt64) -> String?)? = nil) -> UInt64? {
        guard !truncated else { return nil }
        guard let raw = window.uint(offset, size: size, endianness) else {
            cutOff(name, at: offset, needing: size)
            return nil
        }
        if recording {
            add(id: nextID(name), name, offset, Int64(size), kind,
                value?(raw) ?? FieldText.number(raw, size: size), note?(raw), .none)
        }
        return raw
    }

    /// Some of a number's bits: the same bytes as another field, said another way.
    /// `shift` and `width` pick the bits out of the `size` bytes at `offset`.
    @discardableResult
    mutating func bits(_ name: String, at offset: Int64, size: Int, shift: Int, width: Int,
                       kind: FieldNode.Kind = .integer,
                       value: ((UInt64) -> String)? = nil, note: String? = nil) -> UInt64? {
        guard !truncated else { return nil }
        guard let raw = window.uint(offset, size: size, endianness) else {
            cutOff(name, at: offset, needing: size)
            return nil
        }
        let mask: UInt64 = width >= 64 ? UInt64.max : (UInt64(1) << UInt64(width)) - 1
        let bitsValue = (raw >> UInt64(shift)) & mask
        if recording {
            add(id: nextID(name), name, offset, Int64(size), kind, value?(bitsValue) ?? "\(bitsValue)", note, .none)
        }
        return bitsValue
    }

    /// `length` bytes with no more to say about them than what they are. Cut to the
    /// window, and said to be so if it had to be.
    @discardableResult
    mutating func bytes(_ name: String, at offset: Int64, length: Int64, kind: FieldNode.Kind = .bytes,
                        value: String? = nil, note: String? = nil) -> ArraySlice<UInt8>? {
        guard !truncated else { return nil }
        let available = max(0, min(length, window.end - offset))
        let held = Int(min(available, Int64(Int32.max)))
        let slice = window.slice(offset, held)
        if available < length {
            truncated = true
            if recording {
                let shortNote = "Cut off: \(FieldText.bytes(length)) are described and \(FieldText.bytes(available)) are in the file here."
                add(id: nextID(name), name, min(max(offset, window.base), window.end), available, .problem,
                    value ?? slice.map { FieldText.hex($0) }, shortNote, .none)
            }
            return slice
        }
        if recording {
            add(id: nextID(name), name, offset, available, kind,
                value ?? slice.map { FieldText.hex($0) }, note, .none)
        }
        return slice
    }

    /// `length` bytes of text.
    @discardableResult
    mutating func text(_ name: String, at offset: Int64, length: Int64, note: String? = nil) -> ArraySlice<UInt8>? {
        guard !truncated else { return nil }
        let available = max(0, min(length, window.end - offset))
        guard available == length, let slice = window.slice(offset, Int(min(length, Int64(Int32.max)))) else {
            cutOff(name, at: offset, needing: Int(min(length, Int64(Int32.max))))
            return nil
        }
        if recording {
            add(id: nextID(name), name, offset, length, .text, FieldText.ascii(slice), note, .none)
        }
        return slice
    }

    /// An address of `size` bytes, written by `format`.
    @discardableResult
    mutating func address(_ name: String, at offset: Int64, size: Int, note: String? = nil,
                          format: ([UInt8]) -> String) -> [UInt8]? {
        guard !truncated else { return nil }
        guard let slice = window.slice(offset, size) else {
            cutOff(name, at: offset, needing: size)
            return nil
        }
        let raw = Array(slice)
        if recording {
            add(id: nextID(name), name, offset, Int64(size), .address, format(raw), note, .none)
        }
        return raw
    }

    // MARK: Groups

    /// A container for the fields `build` adds. Its length is what the parser says it
    /// is, cut to the window, and the fields inside are checked against the same window.
    mutating func group(_ name: String, at offset: Int64, length: Int64, kind: FieldNode.Kind = .container,
                        value: String? = nil, note: String? = nil, build: (inout FieldList) -> Void) {
        guard !truncated else { return }
        let available = max(0, min(length, window.end - offset))
        if !recording {
            var quiet = FieldList(idPrefix: idPrefix, window: window, endianness: endianness, recording: false)
            build(&quiet)
            if quiet.truncated { truncated = true }
            return
        }
        let id = nextID(name)
        var inner = FieldList(idPrefix: id, window: window, endianness: endianness, recording: true)
        build(&inner)
        add(id: id, name, min(max(offset, window.base), window.end), available, kind,
            inner.groupValue ?? value, inner.groupNote ?? note, .list(inner.nodes))
        if inner.truncated { truncated = true }
    }

    /// A container whose fields are made only when it is opened. `make` is given the
    /// container's id, to build the ids of what is inside it.
    mutating func deferredGroup(_ name: String, at offset: Int64, length: Int64, kind: FieldNode.Kind = .container,
                                value: String? = nil, note: String? = nil, make: @escaping (String) -> [FieldNode]) {
        guard !truncated, recording else { return }
        let available = max(0, min(length, window.end - offset))
        let id = nextID(name)
        add(id: id, name, min(max(offset, window.base), window.end), available, kind, value, note,
            .deferred(DeferredChildren { make(id) }))
    }

    /// Something wrong with the file at this point, said in a node of its own.
    mutating func problem(_ message: String, at offset: Int64, length: Int64 = 0, name: String = "Problem") {
        guard recording else { return }
        let start = min(max(offset, window.base), window.end)
        let held = max(0, min(length, window.end - start))
        add(id: nextID(name), name, start, held, .problem, nil, message, .none)
    }

    /// A node made by the caller, which must keep to this list's order and window.
    mutating func add(_ node: FieldNode) {
        guard recording else { return }
        nodes.append(node)
    }

    /// A node whose id is made here, so that two fields of one name in one list do not share one.
    mutating func claimID(_ name: String) -> String {
        nextID(name)
    }

    /// Marks the list as having run out of bytes, for a caller that found out for itself.
    mutating func markTruncated() {
        truncated = true
    }

    // MARK: Inside

    private mutating func add(id: String, _ name: String, _ offset: Int64, _ length: Int64, _ kind: FieldNode.Kind,
                              _ value: String?, _ note: String?, _ children: FieldNode.Children) {
        nodes.append(FieldNode(id: id, name: name, offset: offset, length: length, kind: kind,
                               value: value, note: note, children: children))
    }

    private mutating func cutOff(_ name: String, at offset: Int64, needing size: Int) {
        truncated = true
        guard recording else { return }
        let start = min(max(offset, window.base), window.end)
        let available = max(0, min(Int64(size), window.end - start))
        add(id: nextID(name), name, start, available, .problem, "cut off",
            "The data ends here: \(name) needs \(FieldText.bytes(Int64(size))) and \(FieldText.bytes(available)) are left.", .none)
    }

    private mutating func nextID(_ name: String) -> String {
        let base = idPrefix + "/" + FieldList.slug(name)
        let count = (used[base] ?? 0) + 1
        used[base] = count
        return count == 1 ? base : base + "#\(count)"
    }

    static func slug(_ name: String) -> String {
        var out = ""
        var lastWasDash = false
        for character in name.lowercased() {
            if character.isLetter || character.isNumber {
                out.append(character)
                lastWasDash = false
            } else if !lastWasDash, !out.isEmpty {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "field" : out
    }
}
