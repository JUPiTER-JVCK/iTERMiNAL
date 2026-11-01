import Foundation

/// What the file browser will hand to Quick Look, and what it calls the
/// temporary copy of a remote file. Foundation only, so the rules are checked
/// in CI; showing the panel itself is `QuickLookPresenter`'s.
enum QuickLookPolicy {
    /// The most that is fetched from a remote host just to look at a file, in
    /// bytes. Quick Look is for a glance: a bigger file is downloaded on
    /// purpose, with the progress and the destination that come with that.
    static let maxRemoteBytes: Int64 = 50_000_000

    enum Refusal: Equatable {
        /// Quick Look shows files. A folder is opened instead.
        case folder
        /// A remote file over `maxRemoteBytes`; its size in bytes.
        case tooLarge(Int64)
    }

    /// Why a file is not previewed, or nil when it may be.
    ///
    /// A local file is passed on whatever its size: it is read in place, by
    /// the system's own previewer. An unknown remote size is allowed: the
    /// listing reports one for every file it can open, and a missing one is a
    /// reason to look, not to refuse.
    static func refusal(isDirectory: Bool, isRemote: Bool, size: Int64?) -> Refusal? {
        if isDirectory { return .folder }
        if isRemote, let size, size > maxRemoteBytes { return .tooLarge(size) }
        return nil
    }

    /// The sentence shown under the list when a file is not previewed.
    static func message(_ refusal: Refusal, name: String) -> String {
        switch refusal {
        case .folder:
            return "Quick Look shows files, not folders."
        case .tooLarge(let size):
            return "\(name) is \(megabytes(size)), more than the \(megabytes(maxRemoteBytes)) "
                + "Quick Look fetches from a remote host. Download it instead."
        }
    }

    /// Whole megabytes, rounded up so a file just over the limit never reads
    /// as equal to it: "51 MB" beside "50 MB".
    static func megabytes(_ bytes: Int64) -> String {
        let whole = (max(bytes, 0) + 999_999) / 1_000_000
        return "\(whole) MB"
    }

    /// A name that is safe to create inside a folder of our own, and that keeps
    /// the extension, which is how Quick Look knows what a file is.
    ///
    /// Only the last component is used; control characters become `_`; a name
    /// that is nothing, or only dots, or still has a separator in it, or is too
    /// long for a file system, becomes `preview` plus the extension if there is
    /// a short one.
    static func safeFileName(_ name: String) -> String {
        let last = (name as NSString).lastPathComponent
        var cleaned = ""
        for scalar in last.unicodeScalars {
            let isControl = scalar.value < 0x20 || scalar.value == 0x7F
            cleaned.unicodeScalars.append(isControl ? "_" : scalar)
        }
        let unusable = cleaned.isEmpty || cleaned == "." || cleaned == ".."
            || cleaned.contains("/") || cleaned.utf8.count > 200
        guard unusable else { return cleaned }
        let ext = (cleaned as NSString).pathExtension
        let keepable = !ext.isEmpty && ext.utf8.count <= 16 && !ext.contains("/")
        return keepable ? "preview.\(ext)" : "preview"
    }
}
