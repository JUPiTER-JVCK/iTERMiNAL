import Foundation

/// Splits what an API client sends into request lines, and refuses a line
/// longer than `limit` bytes.
///
/// The server used to append to one buffer until a newline came, with no
/// limit, and it does that before a request's token is checked. Only this
/// user's processes can reach the socket, so this is not about who may
/// connect: it keeps one connection from making the app hold as much memory
/// as it cares to send without a newline.
///
/// A line of exactly `limit` bytes is accepted. One byte more is refused,
/// whether or not its newline has arrived, so between reads the buffer holds
/// at most `limit` bytes as long as the caller takes every line `next()`
/// offers before appending more.
struct RequestLineBuffer {
    /// The longest request line accepted, its newline not counted: 1 MiB.
    static let defaultLimit = 1 << 20

    enum Next: Equatable {
        /// One complete line, without its newline. It may be empty.
        case line(Data)
        /// The line being received is longer than the limit. Every later call
        /// says the same, whatever is appended: the caller ends the connection.
        case tooLong
    }

    let limit: Int
    private var pending = Data()

    init(limit: Int = RequestLineBuffer.defaultLimit) {
        self.limit = limit
    }

    /// Bytes received that are not yet part of a line handed out.
    var pendingCount: Int { pending.count }

    /// What to tell a client whose line was refused.
    var refusal: String {
        "Request line is longer than \(limit) bytes. The connection is closed."
    }

    mutating func append<Bytes: Sequence>(_ bytes: Bytes) where Bytes.Element == UInt8 {
        pending.append(contentsOf: bytes)
    }

    /// The next complete line; `.tooLong` once the line being received is over
    /// the limit; nil when more bytes are needed first.
    mutating func next() -> Next? {
        if let newline = pending.firstIndex(of: 0x0A) {
            // A newline past the limit cannot rescue the line before it, and
            // nothing after that line is read: lines are answered in order.
            guard newline - pending.startIndex <= limit else { return .tooLong }
            let line = pending.subdata(in: pending.startIndex..<newline)
            pending.removeSubrange(pending.startIndex...newline)
            return .line(line)
        }
        return pending.count > limit ? .tooLong : nil
    }
}
