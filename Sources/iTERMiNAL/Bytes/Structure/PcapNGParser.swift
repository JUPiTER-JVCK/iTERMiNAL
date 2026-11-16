import Foundation

/// A pcapng capture (Wireshark's default format): a file of blocks, each with its type and
/// its length at both ends. A section header says which way round the numbers are; interface
/// description blocks say what each interface's packets are and how finely they are timed;
/// enhanced packet blocks hold the packets.
///
/// Listed block by block, with a one-line summary for every packet; what is inside a block, and
/// a packet taken apart, is made when it is opened.
enum PcapNGParser: FormatParser {
    static let identity = FormatIdentity(id: "pcapng", name: "a packet capture (pcapng)", detail: "pcapng file format", hasParser: true)

    private struct Interface {
        var linkType: UInt32 = 1
        var snapLength: UInt32 = 0
        var name: String?
        /// Ticks to the second: 10^6 unless the interface says otherwise.
        var ticksPerSecond: UInt64 = 1_000_000
        var digits = 6
    }

    static func matches(head: [UInt8], length: Int64) -> Bool {
        head.count >= 4 && head[0] == 0x0A && head[1] == 0x0D && head[2] == 0x0D && head[3] == 0x0A
    }

    static func parse(_ source: ByteSource, context: ParseContext) -> ParseOutcome {
        var outcome = ParseOutcome()
        let total = source.count
        var endianness: Endianness = .little
        var interfaces: [Interface] = []
        var position: Int64 = 0
        var blockNumber = 0
        var packets = 0
        var problems: [String] = []

        while position < total {
            if blockNumber >= context.maxRecords {
                outcome.listingLimit = "The first \(context.maxRecords) blocks are listed; the rest of the file is in the dump."
                outcome.roots.append(FieldNode(id: "pcapng/more", name: "More blocks", offset: position, length: total - position,
                                               kind: .bytes, value: "not listed", note: "Listing stops after \(context.maxRecords) blocks."))
                break
            }
            if context.isCancelled() {
                problems.append("Stopped before the end of the file.")
                break
            }
            let remaining = total - position
            let peek = ByteWindow(source: source, at: position, count: 12)
            // A section header's type is the same either way round, and says which way round its length is.
            if peek.slice(position, 4).map(Array.init) == [0x0A, 0x0D, 0x0D, 0x0A], let order = peek.slice(position + 8, 4) {
                if Array(order) == [0x4D, 0x3C, 0x2B, 0x1A] {
                    endianness = .little
                } else if Array(order) == [0x1A, 0x2B, 0x3C, 0x4D] {
                    endianness = .big
                } else {
                    problems.append("The section header's byte-order magic is neither 0x1A2B3C4D nor its reverse, so numbers are read little-endian.")
                }
                interfaces.removeAll()
            }
            guard remaining >= 12, let type = peek.u32(position, endianness), let length32 = peek.u32(position + 4, endianness) else {
                outcome.roots.append(FieldNode(id: "pcapng/cut", name: "Cut off", offset: position, length: remaining, kind: .problem,
                                               value: "\(FieldText.bytes(remaining)) left",
                                               note: "A block is at least 12 bytes: its type, its length, and its length again."))
                problems.append("The file ends inside a block, at \(FieldText.hexNumber(UInt64(position), size: 1)).")
                break
            }
            let totalLength = Int64(length32)
            blockNumber += 1
            let start = position
            let id = "pcapng/block\(blockNumber)"
            guard totalLength >= 12, totalLength % 4 == 0, totalLength <= remaining else {
                let why = totalLength < 12 || totalLength % 4 != 0
                    ? "A block's length is at least 12 and a multiple of 4; this one says \(totalLength)."
                    : "The block says it is \(FieldText.bytes(totalLength)) long and the file has \(FieldText.bytes(remaining)) left."
                outcome.roots.append(FieldNode(id: id, name: blockName(type, packetNumber: nil, interfaceNumber: nil), offset: start, length: remaining,
                                               kind: .problem, value: "bad length", note: why))
                problems.append("Block \(blockNumber) at \(FieldText.hexNumber(UInt64(start), size: 1)): \(why)")
                break
            }

            var name = blockName(type, packetNumber: nil, interfaceNumber: nil)
            var value = FieldText.bytes(totalLength)
            var packetLinkType: UInt32 = 1
            var packetTicks: UInt64 = 1_000_000
            var packetDigits = 6

            switch type {
            case 0x0A0D0D0A:
                let window = ByteWindow(source: source, at: position, count: Int(min(totalLength, 4096)))
                let major = window.u16(position + 12, endianness) ?? 0
                let minor = window.u16(position + 14, endianness) ?? 0
                let application = optionText(window: window, from: position + 24, to: position + totalLength - 4, endianness: endianness, code: 4)
                value = "pcapng \(major).\(minor) · " + (endianness == .little ? "little-endian" : "big-endian")
                    + (application.map { " · " + $0 } ?? "")
            case 1:
                let window = ByteWindow(source: source, at: position, count: Int(min(totalLength, 4096)))
                var interface = Interface()
                interface.linkType = UInt32(window.u16(position + 8, endianness) ?? 1)
                interface.snapLength = window.u32(position + 12, endianness) ?? 0
                let optionsStart = position + 16
                let optionsEnd = position + totalLength - 4
                interface.name = optionText(window: window, from: optionsStart, to: optionsEnd, endianness: endianness, code: 2)
                if let resolution = optionBytes(window: window, from: optionsStart, to: optionsEnd, endianness: endianness, code: 9), let byte = resolution.first {
                    let (ticks, digits) = resolutionOf(byte)
                    interface.ticksPerSecond = ticks
                    interface.digits = digits
                }
                name = blockName(type, packetNumber: nil, interfaceNumber: interfaces.count)
                value = (PacketNames.linkTypes[interface.linkType] ?? "link type \(interface.linkType)")
                    + (interface.name.map { " · " + $0 } ?? "") + " · snap \(interface.snapLength)"
                interfaces.append(interface)
            case 6:
                packets += 1
                let window = ByteWindow(source: source, at: position, count: 8 + 20 + 128)
                let interfaceID = Int(window.u32(position + 8, endianness) ?? 0)
                let high = UInt64(window.u32(position + 12, endianness) ?? 0)
                let low = UInt64(window.u32(position + 16, endianness) ?? 0)
                let captured = Int64(window.u32(position + 20, endianness) ?? 0)
                let interface = interfaceID < interfaces.count ? interfaces[interfaceID] : Interface()
                packetLinkType = interface.linkType
                packetTicks = interface.ticksPerSecond
                packetDigits = interface.digits
                name = blockName(type, packetNumber: packets, interfaceNumber: nil)
                let held = max(0, min(captured, totalLength - 32))
                let bytes = Array(window.bytes.dropFirst(28).prefix(Int(min(held, 128))))
                let summary = PacketDissector.dissect(linkType: interface.linkType, window: ByteWindow(base: position + 28, bytes: bytes),
                                                      idPrefix: "", recording: false).summary
                let stamp = timestamp(ticks: high << 32 | low, ticksPerSecond: interface.ticksPerSecond, digits: interface.digits)
                value = "\(stamp.clock) · \(captured) B · \(summary)"
            case 3:
                packets += 1
                let window = ByteWindow(source: source, at: position, count: 8 + 4 + 128)
                let original = Int64(window.u32(position + 8, endianness) ?? 0)
                let interface = interfaces.first ?? Interface()
                packetLinkType = interface.linkType
                name = blockName(type, packetNumber: packets, interfaceNumber: nil)
                let held = max(0, min(original, totalLength - 16))
                let bytes = Array(window.bytes.dropFirst(12).prefix(Int(min(held, 128))))
                let summary = PacketDissector.dissect(linkType: interface.linkType, window: ByteWindow(base: position + 12, bytes: bytes),
                                                      idPrefix: "", recording: false).summary
                value = "\(original) B · \(summary)"
            default:
                break
            }

            let capturedType = type
            let capturedEndianness = endianness
            let capturedLinkType = packetLinkType
            let capturedTicks = packetTicks
            let capturedDigits = packetDigits
            outcome.roots.append(FieldNode(
                id: id, name: name, offset: start, length: totalLength, kind: .container, value: value,
                note: blockNote(type),
                children: .deferred(DeferredChildren {
                    blockChildren(id: id, source: source, position: start, totalLength: totalLength, type: capturedType,
                                  endianness: capturedEndianness, linkType: capturedLinkType, ticksPerSecond: capturedTicks,
                                  digits: capturedDigits)
                })))
            position += totalLength
        }

        outcome.problems = Array(problems.prefix(20))
        outcome.summary = "pcapng capture, \(packets) \(packets == 1 ? "packet" : "packets"), \(interfaces.count) \(interfaces.count == 1 ? "interface" : "interfaces")"
        return outcome
    }

    // MARK: Inside a block

    private static func blockChildren(id: String, source: ByteSource, position: Int64, totalLength: Int64, type: UInt32,
                                      endianness: Endianness, linkType: UInt32, ticksPerSecond: UInt64, digits: Int) -> [FieldNode] {
        let window = ByteWindow(source: source, at: position, count: Int(min(totalLength, 262_144 + 64)))
        var list = FieldList(idPrefix: id, window: window, endianness: endianness)
        let body = position + 8
        let bodyEnd = position + totalLength - 4

        list.uint("Block type", at: position, size: 4, value: { FieldText.hexNumber($0, size: 4) + " · " + blockName(UInt32(truncatingIfNeeded: $0), packetNumber: nil, interfaceNumber: nil) })
        list.uint("Block total length", at: position + 4, size: 4, value: { FieldText.bytes(Int64($0)) },
                  note: { _ in "From the first byte of the type to the last of this length, and written again at the end." })

        switch type {
        case 0x0A0D0D0A:
            list.uint("Byte-order magic", at: body, size: 4, kind: .magic, value: { FieldText.hexNumber($0, size: 4) },
                      note: { _ in "Read as 0x1A2B3C4D, the numbers in this section are in the byte order they were read in." })
            list.uint("Major version", at: body + 4, size: 2)
            list.uint("Minor version", at: body + 6, size: 2)
            list.uint("Section length", at: body + 8, size: 8, value: { raw in
                let signed = Int64(bitPattern: raw)
                return signed == -1 ? "-1 · not stated" : FieldText.bytes(signed)
            })
            appendOptions(&list, id: id, window: window, from: body + 16, to: bodyEnd, endianness: endianness, type: type)
        case 1:
            list.uint("Link type", at: body, size: 2, value: { PacketNames.linkType(UInt32(truncatingIfNeeded: $0)) })
            list.bytes("Reserved", at: body + 2, length: 2, kind: .padding)
            list.uint("Snap length", at: body + 4, size: 4, value: { FieldText.bytes(Int64($0)) },
                      note: { _ in "Zero means no limit." })
            appendOptions(&list, id: id, window: window, from: body + 8, to: bodyEnd, endianness: endianness, type: type)
        case 6:
            list.uint("Interface ID", at: body, size: 4, note: { _ in "Which interface description block, counting from 0 in this section, this packet came in on." })
            // The two halves of one 64-bit tick count, as a group so that the fields stay in file order.
            list.group("Timestamp", at: body + 4, length: 8, kind: .time) { f in
                let high = f.uint("High 32 bits", at: body + 4, size: 4, kind: .time)
                let low = f.uint("Low 32 bits", at: body + 8, size: 4, kind: .time)
                if let high, let low {
                    f.groupValue = timestamp(ticks: high << 32 | low, ticksPerSecond: ticksPerSecond, digits: digits).utc
                    f.groupNote = "The two halves together are a count of ticks of 1/\(ticksPerSecond) of a second since 1970."
                }
            }
            let captured = list.uint("Captured length", at: body + 12, size: 4, value: { FieldText.bytes(Int64($0)) })
            list.uint("Original length", at: body + 16, size: 4, value: { FieldText.bytes(Int64($0)) })
            if let captured {
                appendPacket(&list, id: id, source: source, window: window, at: body + 20, declared: Int64(captured), limit: bodyEnd,
                             linkType: linkType, endianness: endianness, type: type)
            }
        case 3:
            let original = list.uint("Original length", at: body, size: 4, value: { FieldText.bytes(Int64($0)) })
            if let original {
                appendPacket(&list, id: id, source: source, window: window, at: body + 4, declared: Int64(original), limit: bodyEnd,
                             linkType: linkType, endianness: endianness, type: type)
            }
        case 5:
            list.uint("Interface ID", at: body, size: 4)
            list.uint("Timestamp (high)", at: body + 4, size: 4, kind: .time)
            list.uint("Timestamp (low)", at: body + 8, size: 4, kind: .time)
            appendOptions(&list, id: id, window: window, from: body + 12, to: bodyEnd, endianness: endianness, type: type)
        case 0x0000_0BAD, 0x4000_0BAD:
            list.uint("Private Enterprise Number", at: body, size: 4, note: { _ in "Who defined this block: a number from IANA's registry." })
            list.bytes("Custom data", at: body + 4, length: max(0, bodyEnd - body - 4))
        default:
            if bodyEnd > body {
                list.bytes("Body", at: body, length: bodyEnd - body,
                           note: type == 4 ? "Name resolution records: addresses and the names they were seen with." : "A block type this view does not take apart; the bytes are in the dump.")
            }
        }

        var nodes = list.nodes
        let trailer = ByteWindow(source: source, at: bodyEnd, count: 4)
        let repeated = trailer.u32(bodyEnd, endianness)
        nodes.append(FieldNode(id: id + "/total-length-again", name: "Block total length (again)", offset: bodyEnd, length: 4, kind: .integer,
                               value: repeated.map { FieldText.bytes(Int64($0)) + ($0 == UInt32(truncatingIfNeeded: totalLength) ? " · matches" : " · does not match") },
                               note: "The length is written again at the end, so a reader can walk the blocks backwards."))
        return nodes
    }

    /// A packet's bytes, taken apart, with the padding to a multiple of four that follows them,
    /// and the options after that.
    private static func appendPacket(_ list: inout FieldList, id: String, source: ByteSource, window: ByteWindow, at start: Int64,
                                     declared: Int64, limit: Int64, linkType: UInt32, endianness: Endianness, type: UInt32) {
        let held = max(0, min(declared, limit - start))
        let dataWindow = ByteWindow(source: source, at: start, count: Int(min(held, 262_144)))
        let dissected = PacketDissector.dissect(linkType: linkType, window: dataWindow, idPrefix: id + "/packet")
        list.add(FieldNode(id: id + "/packet", name: "Packet data", offset: start, length: held, kind: held == declared ? .container : .problem,
                           value: dissected.summary,
                           note: held < declared ? "The block says \(FieldText.bytes(declared)) but only \(FieldText.bytes(held)) fit in it." : nil,
                           children: dissected.nodes.isEmpty ? .none : .list(dissected.nodes)))
        let padded = (held + 3) / 4 * 4
        if padded > held {
            list.add(FieldNode(id: id + "/padding", name: "Padding", offset: start + held, length: padded - held, kind: .padding,
                               note: "Packet data is padded with zeros to a multiple of four bytes."))
        }
        if type == 6 {
            appendOptions(&list, id: id, window: window, from: start + padded, to: limit, endianness: endianness, type: type)
        }
    }

    // MARK: Options

    /// The options in `start..<end`, as a group of one node each.
    private static func appendOptions(_ list: inout FieldList, id: String, window: ByteWindow, from start: Int64, to end: Int64,
                                      endianness: Endianness, type: UInt32) {
        guard end - start >= 4 else { return }
        var children: [FieldNode] = []
        var cursor = start
        var count = 0
        let optionsID = id + "/options"
        while cursor + 4 <= end, count < 64 {
            guard let code = window.u16(cursor, endianness), let length = window.u16(cursor + 2, endianness) else { break }
            let padded = (Int64(length) + 3) / 4 * 4
            if code == 0 {
                children.append(FieldNode(id: optionsID + "/end", name: "End of options", offset: cursor, length: 4, kind: .padding))
                cursor += 4
                break
            }
            guard cursor + 4 + padded <= end else {
                children.append(FieldNode(id: optionsID + "/bad\(count)", name: "Bad option", offset: cursor, length: end - cursor, kind: .problem,
                                          value: "length \(length)", note: "The option does not fit in the bytes that are left."))
                cursor = end
                break
            }
            let bytes = window.slice(cursor + 4, Int(length))
            children.append(FieldNode(id: optionsID + "/\(count)", name: optionName(type: type, code: code), offset: cursor, length: 4 + padded,
                                      kind: .container, value: bytes.flatMap { optionValue(type: type, code: code, bytes: Array($0), endianness: endianness) }))
            cursor += 4 + padded
            count += 1
        }
        guard !children.isEmpty else { return }
        list.add(FieldNode(id: optionsID, name: "Options", offset: start, length: max(0, cursor - start), kind: .container,
                           value: "\(children.count) \(children.count == 1 ? "option" : "options")", children: .list(children)))
        if end > cursor {
            list.add(FieldNode(id: id + "/after-options", name: "Padding", offset: cursor, length: end - cursor, kind: .padding))
        }
    }

    private static func optionName(type: UInt32, code: UInt16) -> String {
        if code == 1 { return "Comment" }
        if code == 2988 || code == 2989 || code == 19372 || code == 19373 { return "Custom option" }
        switch (type, code) {
        case (0x0A0D0D0A, 2): return "Hardware"
        case (0x0A0D0D0A, 3): return "Operating system"
        case (0x0A0D0D0A, 4): return "Application"
        case (1, 2): return "Interface name"
        case (1, 3): return "Interface description"
        case (1, 4): return "IPv4 address"
        case (1, 5): return "IPv6 address"
        case (1, 6): return "MAC address"
        case (1, 8): return "Speed"
        case (1, 9): return "Timestamp resolution"
        case (1, 10): return "Time zone"
        case (1, 11): return "Filter"
        case (1, 12): return "Operating system"
        case (1, 13): return "FCS length"
        case (1, 14): return "Timestamp offset"
        case (1, 15): return "Hardware"
        case (6, 2): return "Flags"
        case (6, 3): return "Hash"
        case (6, 4): return "Dropped packets"
        case (6, 5): return "Packet ID"
        case (6, 6): return "Queue"
        case (6, 7): return "Verdict"
        case (5, 2): return "Start time"
        case (5, 3): return "End time"
        case (5, 4): return "Packets received"
        case (5, 5): return "Packets dropped"
        default: return "Option \(code)"
        }
    }

    private static func optionValue(type: UInt32, code: UInt16, bytes: [UInt8], endianness: Endianness) -> String? {
        let textual: Bool
        switch (type, code) {
        case (_, 1), (0x0A0D0D0A, 2), (0x0A0D0D0A, 3), (0x0A0D0D0A, 4), (1, 2), (1, 3), (1, 11), (1, 12), (1, 15): textual = true
        default: textual = false
        }
        if textual, !bytes.isEmpty { return "\"" + String(decoding: bytes, as: UTF8.self) + "\"" }
        if type == 1, code == 9, let byte = bytes.first {
            return (byte & 0x80 == 0 ? "10^-\(byte & 0x7F) s" : "2^-\(byte & 0x7F) s") + " per tick"
        }
        if type == 1, code == 8, bytes.count == 8 {
            let window = ByteWindow(base: 0, bytes: bytes)
            return window.u64(0, endianness).map { "\($0) bits per second" }
        }
        if type == 1, code == 4, bytes.count == 8 { return PacketNames.ipv4(Array(bytes[0..<4])) + " / " + PacketNames.ipv4(Array(bytes[4..<8])) }
        if type == 1, code == 6, bytes.count == 6 { return PacketNames.mac(bytes) }
        return bytes.isEmpty ? nil : FieldText.hex(bytes[...])
    }

    /// The text of the option `code` in `start..<end`, if there is one.
    private static func optionText(window: ByteWindow, from start: Int64, to end: Int64, endianness: Endianness, code wanted: UInt16) -> String? {
        optionBytes(window: window, from: start, to: end, endianness: endianness, code: wanted).flatMap { bytes in
            bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
        }
    }

    private static func optionBytes(window: ByteWindow, from start: Int64, to end: Int64, endianness: Endianness, code wanted: UInt16) -> [UInt8]? {
        var cursor = start
        var count = 0
        while cursor + 4 <= end, count < 64 {
            guard let code = window.u16(cursor, endianness), let length = window.u16(cursor + 2, endianness) else { return nil }
            if code == 0 { return nil }
            if code == wanted { return window.slice(cursor + 4, Int(length)).map(Array.init) }
            cursor += 4 + (Int64(length) + 3) / 4 * 4
            count += 1
        }
        return nil
    }

    // MARK: Words

    private static func resolutionOf(_ byte: UInt8) -> (ticks: UInt64, digits: Int) {
        let exponent = Int(byte & 0x7F)
        if byte & 0x80 == 0 {
            guard exponent <= 18 else { return (1_000_000, 6) }
            var ticks: UInt64 = 1
            for _ in 0..<exponent { ticks *= 10 }
            return (ticks, min(exponent, 9))
        }
        guard exponent <= 62 else { return (1_000_000, 6) }
        return (UInt64(1) << UInt64(exponent), 9)
    }

    /// A tick count as a clock reading and a full date, to the precision the interface counts in.
    private static func timestamp(ticks: UInt64, ticksPerSecond: UInt64, digits: Int) -> (clock: String, utc: String) {
        let perSecond = max(1, ticksPerSecond)
        let seconds = ticks / perSecond
        let remainder = ticks % perSecond
        let (product, overflow) = remainder.multipliedReportingOverflow(by: 1_000_000_000)
        let nanoseconds = overflow ? UInt64(Double(remainder) / Double(perSecond) * 1e9) : product / perSecond
        let shown = min(max(digits, 0), 9)
        var divisor: UInt64 = 1
        for _ in 0..<(9 - shown) { divisor *= 10 }
        let clock = PacketNames.clock(seconds: Int64(truncatingIfNeeded: seconds), fraction: nanoseconds / divisor, digits: shown)
        let date = String(ByteInterpreter.utcString(unixSeconds: Int64(truncatingIfNeeded: seconds)).dropLast(4))
        let fraction = shown > 0 ? "." + String(clock.suffix(shown)) : ""
        return (clock, date + fraction + " UTC")
    }

    private static func blockName(_ type: UInt32, packetNumber: Int?, interfaceNumber: Int?) -> String {
        switch type {
        case 0x0A0D0D0A: return "Section header"
        case 1: return interfaceNumber.map { "Interface \($0)" } ?? "Interface description"
        case 3: return packetNumber.map { "Packet \($0) (simple)" } ?? "Simple packet"
        case 4: return "Name resolution"
        case 5: return "Interface statistics"
        case 6: return packetNumber.map { "Packet \($0)" } ?? "Enhanced packet"
        case 0x0000_0BAD, 0x4000_0BAD: return "Custom block"
        default: return "Block " + FieldText.hexNumber(UInt64(type), size: 4)
        }
    }

    private static func blockNote(_ type: UInt32) -> String? {
        switch type {
        case 0x0A0D0D0A: return "Starts a section: says which way round the numbers are, and what wrote the file."
        case 1: return "Says what one interface's packets are (the link type) and how finely they are timed."
        case 6: return "A captured packet, with the interface it came in on and when."
        case 3: return "A captured packet with no timestamp or interface of its own."
        case 4: return "Names for addresses, as the capturing program resolved them."
        case 5: return "Counts kept by an interface: packets seen, packets dropped."
        default: return nil
        }
    }
}
