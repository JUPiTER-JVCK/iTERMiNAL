import Foundation

/// What the Bytes panel will open, and what it says when it will not. Foundation
/// only, so the rules are checked in CI.
///
/// There is no size limit: the panel reads a window at a time, so the size of a
/// file is no reason to refuse it. What is refused is anything that is not a
/// fixed run of bytes — a folder, a pipe, a device — because reading one would
/// either wait forever or show something that changes while it is shown.
enum BytesFilePolicy {
    enum Refusal: Error, Equatable {
        /// A folder, or something a Finder treats as one, like an app.
        case directory
        /// A named pipe, socket or device; what it is, ready to read in a sentence.
        case special(String)
        /// It exists but could not be opened; the `errno`.
        case unreadable(Int32)
        /// A regular file with nothing in it. Not an error, but there is nothing to show.
        case empty
    }

    /// Why a file with this `st_mode` is not shown, or nil when it is a regular file.
    static func refusal(forMode mode: mode_t) -> Refusal? {
        switch mode & S_IFMT {
        case S_IFREG: return nil
        case S_IFDIR: return .directory
        case S_IFIFO: return .special("a named pipe")
        case S_IFSOCK: return .special("a socket")
        case S_IFCHR: return .special("a character device")
        case S_IFBLK: return .special("a block device")
        default: return .special("not a regular file")
        }
    }

    /// Whether this is a state the person should be told is a problem. An empty
    /// file is opened as far as it goes: the panel says so quietly.
    static func isProblem(_ refusal: Refusal) -> Bool {
        refusal != .empty
    }

    /// The sentence shown in place of the bytes.
    static func message(_ refusal: Refusal, name: String) -> String {
        switch refusal {
        case .directory:
            return "\(name) is a folder. Drop a file to see its bytes."
        case .special(let kind):
            return "\(name) is \(kind), so there is no fixed set of bytes to show."
        case .unreadable(let code):
            if code == EACCES || code == EPERM {
                return "\(name) cannot be read: permission denied."
            }
            return "\(name) could not be opened: \(String(cString: strerror(code)))."
        case .empty:
            return "\(name) is empty: there are no bytes to show."
        }
    }
}
