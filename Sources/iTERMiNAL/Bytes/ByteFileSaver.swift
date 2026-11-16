import Foundation

/// Writes an edited buffer back over the file it was opened from, without ever leaving a half-written file.
///
/// A save is never in place. The new content is written to a file of its own beside the original, checked,
/// and only then swapped in with `replaceItemAt`, so a crash, a full disk or a failed read in the middle
/// leaves the original as it was. When only bytes were overwritten (no insert, no delete) the original is
/// copied first, which a file system that can clone files (APFS) does without writing the data, and only
/// the changed bytes are written into the copy: changing one byte of a multi-gigabyte video is not a
/// multi-gigabyte write. Otherwise the whole content is streamed.
///
/// Foundation only, so the rules (what is refused, what is checked before the swap, what is left behind) are
/// checked in CI against real files.
enum ByteFileSaver {
    enum Failure: Error, Equatable {
        /// The file was changed, replaced or removed since it was opened: saving would write over someone else's changes.
        case changedOnDisk(Staleness)
        /// The folder has less room than the new content needs.
        case notEnoughSpace(needed: Int64, available: Int64)
        /// There would be nothing left. The panel does not open empty files, so it will not make one.
        case wouldBeEmpty
        /// A system call failed; the words for it.
        case cannotWrite(String)
        /// What was written is not the length of what was meant to be written. Nothing was swapped in.
        case lengthMismatch(written: Int64, expected: Int64)
        /// The original could not be read in full (it changed underneath).
        case unreadable(offset: Int64)
        /// The file has this many names (hard links). A save puts a new file under one of them, and the others would
        /// be left with the old bytes without anyone being told.
        case hasOtherNames(Int)
    }

    /// How many names the file at `path` has, following a link to the file it names; nil if it cannot be looked at.
    static func nameCount(ofFileAt path: String) -> Int? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Int(info.st_nlink)
    }

    /// How a save was made, for the one line that says so.
    enum Method: Equatable {
        /// A copy of the file with the changed bytes written into it.
        case patchedCopy(changedBytes: Int64)
        /// The whole content written out.
        case rewritten
    }

    /// Room left in a folder, for a check that can be given another answer.
    typealias FreeSpace = (_ folder: String) -> Int64?

    static func freeSpace(inFolder folder: String) -> Int64? {
        var info = statvfs()
        guard statvfs(folder, &info) == 0 else { return nil }
        return Int64(info.f_bavail) * Int64(info.f_frsize)
    }

    /// More than the content, for the folder's own bookkeeping.
    static let spaceMargin: Int64 = 1 << 20

    /// Whether a copy of a file in `folder` shares the original's data until one of them is changed, as APFS does.
    /// There, a copy of a file of any size needs no room of its own.
    static func clonesFiles(inFolder folder: URL) -> Bool {
        #if canImport(Darwin)
        return (try? folder.resourceValues(forKeys: [.volumeSupportsFileCloningKey]))?.volumeSupportsFileCloning ?? false
        #else
        return false
        #endif
    }

    /// The room a save of `buffer` needs in its folder: all of it, unless only bytes were overwritten and the
    /// volume clones files, when it is the changed bytes alone.
    static func spaceNeeded(for buffer: ByteEditBuffer, clones: Bool) -> Int64 {
        guard clones, let changed = buffer.changedRanges() else { return buffer.length }
        return changed.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    /// Saves `buffer` over the file `source` was opened from, and says how. Throws without having changed the file.
    ///
    /// - Parameters:
    ///   - keepsBackup: leaves the file as it was beside the new one, as `name.bak`, replacing an earlier backup.
    ///   - chunk: how much is written at a time.
    @discardableResult
    static func save(_ buffer: ByteEditBuffer, over source: FileByteSource, keepsBackup: Bool, chunk: Int = 1 << 20,
                     freeSpace: FreeSpace = ByteFileSaver.freeSpace(inFolder:)) throws -> Method {
        let state = source.staleness()
        guard state == .unchanged else { throw Failure.changedOnDisk(state) }
        guard buffer.length > 0 else { throw Failure.wouldBeEmpty }

        // Through a link to the file it names, so that the link is kept and the file is the one written.
        let original = URL(fileURLWithPath: source.path).resolvingSymlinksInPath()
        let folder = original.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent(".\(original.lastPathComponent).iterminal-\(UUID().uuidString.prefix(8)).tmp")

        var info = stat()
        guard stat(original.path, &info) == 0 else { throw Failure.cannotWrite(String(cString: strerror(errno))) }
        guard info.st_nlink <= 1 else { throw Failure.hasOtherNames(Int(info.st_nlink)) }
        let permissions = info.st_mode & 0o7777

        // A copy needs room for the whole file, except on a volume that clones: there, changing one byte of a
        // file bigger than the room that is left is still a save that fits.
        let needed = spaceNeeded(for: buffer, clones: clonesFiles(inFolder: folder))
        if let available = freeSpace(folder.path), available < needed + spaceMargin {
            throw Failure.notEnoughSpace(needed: needed, available: available)
        }

        let method: Method
        do {
            if let changed = buffer.changedRanges() {
                try FileManager.default.copyItem(at: original, to: temporary)
                try patch(temporary.path, with: buffer, ranges: changed, chunk: chunk)
                method = .patchedCopy(changedBytes: changed.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) })
            } else {
                try write(buffer, to: temporary.path, permissions: permissions, chunk: chunk)
                method = .rewritten
            }
            var written = stat()
            guard stat(temporary.path, &written) == 0 else { throw Failure.cannotWrite(String(cString: strerror(errno))) }
            guard Int64(written.st_size) == buffer.length else {
                throw Failure.lengthMismatch(written: Int64(written.st_size), expected: buffer.length)
            }
            try swapIn(temporary, over: original, keepsBackup: keepsBackup)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            if let failure = error as? Failure { throw failure }
            if let editFailure = error as? ByteEditError, case .unreadable(let offset) = editFailure { throw Failure.unreadable(offset: offset) }
            throw Failure.cannotWrite(error.localizedDescription)
        }
        return method
    }

    // MARK: Swapping

    /// Puts the new file where the original is, keeping the original as `name.bak` if asked.
    ///
    /// On macOS `replaceItemAt` does it, which keeps what a rename would lose of the original file's
    /// own details (its Finder tags, extended attributes, creation date). Elsewhere (where this is only
    /// checked) a copy for the backup and an atomic rename do.
    private static func swapIn(_ temporary: URL, over original: URL, keepsBackup: Bool) throws {
        let backupName = original.lastPathComponent + ".bak"
        #if canImport(Darwin)
        _ = try FileManager.default.replaceItemAt(original, withItemAt: temporary,
                                                  backupItemName: keepsBackup ? backupName : nil,
                                                  options: keepsBackup ? [.withoutDeletingBackupItem] : [])
        #else
        if keepsBackup {
            let backup = original.deletingLastPathComponent().appendingPathComponent(backupName)
            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.copyItem(at: original, to: backup)
        }
        guard rename(temporary.path, original.path) == 0 else { throw Failure.cannotWrite(String(cString: strerror(errno))) }
        #endif
    }

    // MARK: Writing

    /// Writes the changed ranges of `buffer` into the file at `path`, which is a copy of the original.
    private static func patch(_ path: String, with buffer: ByteEditBuffer, ranges: [Range<Int64>], chunk: Int) throws {
        let descriptor = open(path, O_WRONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.cannotWrite(String(cString: strerror(errno))) }
        defer { _ = close(descriptor) }
        let step = Int64(max(1, chunk))
        for range in ranges {
            var position = range.lowerBound
            while position < range.upperBound {
                let end = min(position + step, range.upperBound)
                let bytes = buffer.read(position..<end)
                guard Int64(bytes.count) == end - position else { throw Failure.unreadable(offset: position + Int64(bytes.count)) }
                try writeAll(descriptor, bytes, at: position)
                position = end
            }
        }
        guard fsync(descriptor) == 0 else { throw Failure.cannotWrite(String(cString: strerror(errno))) }
    }

    /// Writes all of `buffer` to a new file at `path`, made with `permissions`.
    private static func write(_ buffer: ByteEditBuffer, to path: String, permissions: mode_t, chunk: Int) throws {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, permissions)
        guard descriptor >= 0 else { throw Failure.cannotWrite(String(cString: strerror(errno))) }
        defer { _ = close(descriptor) }
        // The mode asked of `open` is cut by the umask; the file should have the original's.
        _ = fchmod(descriptor, permissions)
        var position: Int64 = 0
        try buffer.stream(chunkSize: chunk) { piece in
            try writeAll(descriptor, Array(piece), at: position)
            position += Int64(piece.count)
        }
        guard fsync(descriptor) == 0 else { throw Failure.cannotWrite(String(cString: strerror(errno))) }
    }

    private static func writeAll(_ descriptor: Int32, _ bytes: [UInt8], at offset: Int64) throws {
        var done = 0
        while done < bytes.count {
            let wrote = bytes.withUnsafeBytes { raw in
                pwrite(descriptor, raw.baseAddress! + done, bytes.count - done, off_t(offset) + off_t(done))
            }
            if wrote > 0 {
                done += wrote
            } else if wrote < 0 && errno == EINTR {
                continue
            } else {
                throw Failure.cannotWrite(wrote < 0 ? String(cString: strerror(errno)) : "A write wrote nothing.")
            }
        }
    }

    /// The words for a failure, for the line the panel shows.
    static func message(_ failure: Failure, name: String) -> String {
        switch failure {
        case .changedOnDisk(let state):
            switch state {
            case .missing: return "\(name) is gone from where it was opened, so it was not saved."
            case .replaced: return "\(name) has been replaced by another file since it was opened, so it was not saved."
            default: return "\(name) was changed by something else since it was opened, so it was not saved."
            }
        case .notEnoughSpace(let needed, let available):
            return "There is not room to save \(name): it needs \(FieldText.bytes(needed)) and \(FieldText.bytes(max(0, available))) are free."
        case .wouldBeEmpty:
            return "That would leave \(name) with no bytes, so it was not saved."
        case .cannotWrite(let why):
            return "\(name) could not be saved: \(why)"
        case .lengthMismatch(let written, let expected):
            return "\(name) was not saved: \(FieldText.bytes(written)) were written and \(FieldText.bytes(expected)) were meant to be."
        case .unreadable(let offset):
            return "\(name) was not saved: the original could not be read at \(offset). It changed while it was open."
        case .hasOtherNames(let count):
            return "\(name) has \(count - 1) other \(count == 2 ? "name" : "names") (hard links). Saving would leave \(count == 2 ? "it" : "them") with the old bytes, so it was not saved."
        }
    }
}
