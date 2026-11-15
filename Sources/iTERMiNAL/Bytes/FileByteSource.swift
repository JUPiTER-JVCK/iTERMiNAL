import Foundation

/// What names one file on disk and how much of it there was, noted when it was
/// opened so a later look can tell whether it is still the same file.
struct FileIdentity: Equatable {
    var device: Int64
    var inode: UInt64
    var size: Int64
    var modifiedSeconds: Int64
    var modifiedNanoseconds: Int64

    init(_ info: stat) {
        device = Int64(truncatingIfNeeded: info.st_dev)
        inode = UInt64(truncatingIfNeeded: info.st_ino)
        size = Int64(info.st_size)
        #if canImport(Darwin)
        modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        #else
        modifiedSeconds = Int64(info.st_mtim.tv_sec)
        modifiedNanoseconds = Int64(info.st_mtim.tv_nsec)
        #endif
    }
}

/// How the file on disk compares with what was opened.
enum Staleness: Equatable {
    case unchanged
    case grew
    case shrank
    /// The same size, written to since.
    case modified
    /// A different file now has the name: replaced by a save that renames, say.
    case replaced
    case missing
}

/// A regular file read in place, a page at a time.
///
/// Reads use `pread`, not a memory map. A mapped file that is truncated while it
/// is open kills the process with SIGBUS the moment a missing page is touched,
/// and nothing in Swift can catch that; a log being rotated or a drive being
/// ejected is all it takes. With `pread` the same event is a short read, which
/// the panel shows as missing bytes.
///
/// A small cache of whole pages keeps scrolling off the disk: a row is a few
/// bytes and the window a few kilobytes, so nearly every read is of a page just
/// read. One lock covers it, so the grid and a background scan can share a source,
/// though a scan that must not push the grid's pages out should have its own.
final class FileByteSource: ByteSource {
    static let pageSize = 64 * 1024
    /// 256 pages of 64 KB: 16 MB.
    static let maxCachedPages = 256

    let path: String
    let count: Int64
    let identity: FileIdentity

    private let descriptor: Int32
    private let lock = NSLock()
    private var pages: [Int64: Page] = [:]
    private var clock: UInt64 = 0

    private struct Page {
        var bytes: [UInt8]
        var lastUsed: UInt64
    }

    private init(path: String, descriptor: Int32, identity: FileIdentity) {
        self.path = path
        self.descriptor = descriptor
        self.identity = identity
        self.count = identity.size
    }

    deinit {
        _ = close(descriptor)
    }

    /// Opens `path` for reading, or says why not.
    ///
    /// The file is opened first and looked at second, through the descriptor, so
    /// what is checked is what is read: a name swapped for something else in
    /// between cannot get past. It is opened without waiting, so a named pipe
    /// with no writer is refused rather than waited on.
    static func opening(path: String) -> Result<FileByteSource, BytesFilePolicy.Refusal> {
        let descriptor = openWithoutWaiting(path)
        guard descriptor >= 0 else {
            let code = errno
            // A socket cannot be opened at all; saying what it is beats "no such device".
            var info = stat()
            if stat(path, &info) == 0, let refusal = BytesFilePolicy.refusal(forMode: info.st_mode) {
                return .failure(refusal)
            }
            return .failure(.unreadable(code))
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let code = errno
            _ = close(descriptor)
            return .failure(.unreadable(code))
        }
        if let refusal = BytesFilePolicy.refusal(forMode: info.st_mode) {
            _ = close(descriptor)
            return .failure(refusal)
        }
        guard info.st_size > 0 else {
            _ = close(descriptor)
            return .failure(.empty)
        }
        return .success(FileByteSource(path: path, descriptor: descriptor, identity: FileIdentity(info)))
    }

    func read(_ range: Range<Int64>) -> [UInt8] {
        let limited = clamped(range)
        guard !limited.isEmpty else { return [] }
        var result: [UInt8] = []
        result.reserveCapacity(Int(limited.upperBound - limited.lowerBound))
        let pageSize = Int64(FileByteSource.pageSize)

        lock.lock()
        defer { lock.unlock() }
        var offset = limited.lowerBound
        while offset < limited.upperBound {
            let index = offset / pageSize
            guard let page = page(at: index) else { break }
            let pageStart = index * pageSize
            let from = Int(offset - pageStart)
            let to = Int(min(limited.upperBound - pageStart, Int64(page.count)))
            guard from < to else { break }
            result.append(contentsOf: page[from..<to])
            offset = pageStart + Int64(to)
            // A short page is the end of what can be read: stop, so the result
            // stays a prefix.
            if to < Int(min(pageSize, limited.upperBound - pageStart)) { break }
        }
        return result
    }

    /// How the file on disk compares with the one opened.
    func staleness() -> Staleness {
        var info = stat()
        guard stat(path, &info) == 0 else { return .missing }
        let now = FileIdentity(info)
        if now.device != identity.device || now.inode != identity.inode { return .replaced }
        if now.size > identity.size { return .grew }
        if now.size < identity.size { return .shrank }
        if now.modifiedSeconds != identity.modifiedSeconds
            || now.modifiedNanoseconds != identity.modifiedNanoseconds { return .modified }
        return .unchanged
    }

    /// Page `index`, from the cache or the file. The lock is held.
    private func page(at index: Int64) -> [UInt8]? {
        clock &+= 1
        if var cached = pages[index] {
            cached.lastUsed = clock
            pages[index] = cached
            return cached.bytes
        }
        let start = index * Int64(FileByteSource.pageSize)
        let want = Int(min(Int64(FileByteSource.pageSize), count - start))
        guard want > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: want)
        var have = 0
        while have < want {
            let got = buffer.withUnsafeMutableBytes { raw in
                pread(descriptor, raw.baseAddress! + have, want - have, off_t(start) + off_t(have))
            }
            if got > 0 {
                have += got
            } else if got < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        // A page that came back short is not kept: the file may grow back.
        guard have == want else { return have > 0 ? Array(buffer[0..<have]) : nil }

        pages[index] = Page(bytes: buffer, lastUsed: clock)
        if pages.count > FileByteSource.maxCachedPages,
           let oldest = pages.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
            pages.removeValue(forKey: oldest)
        }
        return buffer
    }
}

/// `open` for reading that never waits, kept out of the class so the name means
/// the system call and not a method.
private func openWithoutWaiting(_ path: String) -> Int32 {
    open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
}
