import Foundation

/// What typing in the dump does to the bytes: where a hex digit lands, what the second digit of a byte
/// changes, which bit a 0 or 1 typed in the Bits outlook sets, where the cursor goes, and what Delete is for.
///
/// Foundation only, so every rule is checked in CI against a plain array rather than seen. The view passes
/// keys in, and takes back the selection to show.
///
/// Two modes. **Overwrite** changes bytes where they are, so no offset moves, which is what matters when
/// studying a format. **Insert** puts new bytes in and pushes the rest along, and Delete takes bytes out;
/// both change every offset after them, which is why they are a mode of their own and Delete does nothing
/// in overwrite mode.
struct ByteTyping {
    enum Mode: String {
        case overwrite
        case insert
    }

    enum Failure: Error, Equatable {
        /// The buffer refused the edit.
        case edit(ByteEditError)
        /// Delete was pressed in overwrite mode.
        case needsInsertMode
        /// There is nothing there to change.
        case nothing
    }

    var mode: Mode = .overwrite
    /// The byte whose first hex digit has been typed, and whose second is awaited.
    private(set) var pendingDigit: Int64?
    /// In insert mode, the last byte of the file when it has just been typed, so that what is typed next goes after it
    /// and the cursor, which cannot be past the last byte, stays on it.
    private(set) var appendingAfter: Int64?

    /// In the Bits outlook, the bit the next 0 or 1 sets: of the byte at `offset`, counted from the left (the highest
    /// bit), as the outlook draws them.
    struct BitPosition: Equatable {
        var offset: Int64
        var index: Int
        /// A bit of this byte has been typed already, so the next is part of the same change.
        var typed: Bool
    }
    private(set) var bitCursor: BitPosition?

    /// Forgets a digit that was half typed: the cursor moved, or something else was done.
    mutating func forget() {
        pendingDigit = nil
        appendingAfter = nil
        bitCursor = nil
    }

    // MARK: Adding at the end

    /// Puts the cursor on the last byte with what is typed next going after it, which is the only way to add bytes
    /// at the end: typing inserts before the byte the cursor is on.
    mutating func beginAppending(to buffer: ByteEditBuffer) -> ByteSelection? {
        pendingDigit = nil
        guard buffer.length > 0 else {
            appendingAfter = nil
            return nil
        }
        appendingAfter = buffer.length - 1
        return ByteSelection(at: buffer.length - 1)
    }

    // MARK: Hex digits

    /// Types one hex digit (0 to 15). The first of a byte's two digits sets its high half and the second its
    /// low half, and the cursor then moves to the next byte. In insert mode the first digit puts a new byte in.
    /// Returns where the cursor goes, or nil if the buffer is empty.
    mutating func hexDigit(_ digit: UInt8, in buffer: inout ByteEditBuffer, at selection: ByteSelection?) throws -> ByteSelection? {
        let digit = digit & 0x0F
        let offset = selection?.lowerBound ?? 0
        bitCursor = nil
        if mode == .overwrite, buffer.length == 0 { throw Failure.nothing }
        do {
            if let pending = pendingDigit, pending == offset, offset < buffer.length {
                // The second digit: the low half of the byte the first made.
                let current = try Self.byte(at: offset, in: buffer)
                try buffer.overwrite(at: offset, with: [(current & 0xF0) | digit], coalescing: true, continuingRun: true)
                pendingDigit = nil
                if offset + 1 < buffer.length {
                    appendingAfter = nil
                    return ByteSelection(at: offset + 1)
                }
                appendingAfter = mode == .insert ? offset : nil
                return ByteSelection(at: offset)
            }
            switch mode {
            case .overwrite:
                let current = try Self.byte(at: offset, in: buffer)
                try buffer.overwrite(at: offset, with: [(digit << 4) | (current & 0x0F)], coalescing: true)
                pendingDigit = offset
                appendingAfter = nil
                return ByteSelection(at: offset)
            case .insert:
                let at = (appendingAfter == offset && offset == buffer.length - 1) ? buffer.length : min(max(offset, 0), buffer.length)
                try buffer.insert(at: at, bytes: [digit << 4], coalescing: true)
                pendingDigit = at
                appendingAfter = nil
                return ByteSelection(at: at)
            }
        } catch let error as ByteEditError {
            throw Failure.edit(error)
        }
    }

    // MARK: Bits

    /// Puts the bit cursor on bit `index` (0 the highest, 7 the lowest) of the byte at `offset`: a click on one of
    /// the eight digits of a cell.
    mutating func placeBit(_ index: Int, at offset: Int64) {
        pendingDigit = nil
        appendingAfter = nil
        bitCursor = BitPosition(offset: offset, index: min(max(index, 0), 7), typed: false)
    }

    /// The bit that the cursor at `selection` is on: the one placed or typed up to, or the highest.
    func bitIndex(at selection: ByteSelection?) -> Int {
        guard let cursor = bitCursor, cursor.offset == (selection?.lowerBound ?? 0) else { return 0 }
        return cursor.index
    }

    /// Types one bit. In overwrite mode it sets the bit under the bit cursor and moves the cursor to the next bit,
    /// and after the eighth (the lowest) to the next byte. In insert mode the first bit of a byte puts a new byte in,
    /// all zero, and the bits typed after it fill it from the left. Returns where the cursor goes.
    mutating func bit(_ value: Bool, in buffer: inout ByteEditBuffer, at selection: ByteSelection?) throws -> ByteSelection? {
        var offset = selection?.lowerBound ?? 0
        let current = bitCursor.flatMap { $0.offset == offset ? $0 : nil }
        var index = current?.index ?? 0
        let continuing = current?.typed ?? false
        pendingDigit = nil
        do {
            if mode == .insert && !continuing {
                let at = (appendingAfter == offset && offset == buffer.length - 1) ? buffer.length : min(max(offset, 0), buffer.length)
                try buffer.insert(at: at, bytes: [value ? 0x80 : 0], coalescing: true)
                offset = at
                index = 0
            } else {
                guard buffer.length > 0, offset >= 0, offset < buffer.length else { throw Failure.nothing }
                let byte = try Self.byte(at: offset, in: buffer)
                let mask = UInt8(0x80) >> UInt8(index)
                try buffer.overwrite(at: offset, with: [value ? byte | mask : byte & ~mask], coalescing: true, continuingRun: continuing)
            }
        } catch let error as ByteEditError {
            throw Failure.edit(error)
        }
        appendingAfter = nil
        if index + 1 < 8 {
            bitCursor = BitPosition(offset: offset, index: index + 1, typed: true)
            return ByteSelection(at: offset)
        }
        bitCursor = nil
        if offset + 1 < buffer.length { return ByteSelection(at: offset + 1) }
        appendingAfter = mode == .insert ? offset : nil
        return ByteSelection(at: offset)
    }

    // MARK: Text

    /// Types characters into the text column, as UTF-8. Overwrite mode replaces the bytes under the cursor
    /// (and stops at the end of the file); insert mode puts them in. Control characters are left out.
    mutating func text(_ text: String, in buffer: inout ByteEditBuffer, at selection: ByteSelection?) throws -> ByteSelection? {
        let bytes = Array(String(text.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }).utf8)
        guard !bytes.isEmpty else { return selection }
        let offset = selection?.lowerBound ?? 0
        pendingDigit = nil
        bitCursor = nil
        do {
            switch mode {
            case .overwrite:
                guard buffer.length > 0 else { throw Failure.nothing }
                let written = try buffer.overwrite(at: offset, with: bytes, coalescing: true)
                appendingAfter = nil
                return ByteSelection(at: min(offset + Int64(written), buffer.length - 1))
            case .insert:
                let at = (appendingAfter == offset && offset == buffer.length - 1) ? buffer.length : min(max(offset, 0), buffer.length)
                try buffer.insert(at: at, bytes: bytes, coalescing: true)
                let next = at + Int64(bytes.count)
                if next >= buffer.length {
                    appendingAfter = buffer.length - 1
                    return ByteSelection(at: buffer.length - 1)
                }
                appendingAfter = nil
                return ByteSelection(at: next)
            }
        } catch let error as ByteEditError {
            throw Failure.edit(error)
        }
    }

    // MARK: Deleting

    /// Takes out the selection, or the byte before the cursor if it is one byte (Backspace). Insert mode only.
    mutating func deleteBackward(in buffer: inout ByteEditBuffer, at selection: ByteSelection?) throws -> ByteSelection? {
        guard mode == .insert else { throw Failure.needsInsertMode }
        forget()
        guard let selection, buffer.length > 0 else { throw Failure.nothing }
        let range: Range<Int64>
        if selection.count > 1 {
            range = selection.range
        } else if selection.lowerBound > 0 {
            range = (selection.lowerBound - 1)..<selection.lowerBound
        } else {
            return selection
        }
        return try remove(range, in: &buffer, cursor: range.lowerBound)
    }

    /// Takes out the selection, or the byte under the cursor (Delete). Insert mode only.
    mutating func deleteForward(in buffer: inout ByteEditBuffer, at selection: ByteSelection?) throws -> ByteSelection? {
        guard mode == .insert else { throw Failure.needsInsertMode }
        forget()
        guard let selection, buffer.length > 0 else { throw Failure.nothing }
        return try remove(selection.range, in: &buffer, cursor: selection.lowerBound)
    }

    private mutating func remove(_ range: Range<Int64>, in buffer: inout ByteEditBuffer, cursor: Int64) throws -> ByteSelection? {
        do {
            try buffer.delete(range)
        } catch let error as ByteEditError {
            throw Failure.edit(error)
        }
        guard buffer.length > 0 else { return nil }
        return ByteSelection(at: min(max(cursor, 0), buffer.length - 1))
    }

    // MARK: Filling

    /// Sets every selected byte to `value`: one step of undo, however many bytes.
    mutating func fill(_ value: UInt8, in buffer: inout ByteEditBuffer, at selection: ByteSelection?) throws {
        forget()
        guard let selection, buffer.length > 0 else { throw Failure.nothing }
        do {
            try buffer.fill(selection.range, with: value)
        } catch let error as ByteEditError {
            throw Failure.edit(error)
        }
    }

    // MARK: Reading

    private static func byte(at offset: Int64, in buffer: ByteEditBuffer) throws -> UInt8 {
        guard offset >= 0, offset < buffer.length else { throw Failure.nothing }
        guard let value = buffer.read(offset..<(offset + 1)).first else { throw Failure.edit(.unreadable(offset: offset)) }
        return value
    }
}
