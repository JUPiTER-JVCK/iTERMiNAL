import Foundation

/// Reads a program's manual page, once, and remembers what it found.
///
/// The one thing it does not do itself is run `man`: that is handed in, as a function
/// from a name to what came out. The app hands in one that runs `/usr/bin/man`; the
/// checks hand in ones that return what they like, so every way it can go wrong —
/// no page, a slow `man`, a name that should never have been asked for — is tried
/// without a Mac.
///
/// Blocking, and meant to be called off the main thread.
final class ManPageReader {
    /// What running `man` for a name left behind.
    struct Outcome: Equatable {
        var status: Int32
        var output: String
        var timedOut: Bool
    }

    enum Result: Equatable {
        case found(ManPage.Excerpt)
        /// There is no manual page by that name on this Mac, or no name `man` may be asked for.
        case missing
        /// `man` could not be run, or did not finish; asking again may work.
        case failed(String)
    }

    private let run: (String) -> Outcome?
    private let lock = NSLock()
    private var remembered: [String: Result] = [:]

    /// - Parameter run: `man <name>` and what it printed, or nil if it could not be started.
    init(run: @escaping (String) -> Outcome?) {
        self.run = run
    }

    /// Whether the name has been looked up already and the answer is kept.
    func hasAnswer(for name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return remembered[name] != nil
    }

    func read(_ name: String, limit: Int = 6_000) -> Result {
        // A name `man` could take for a flag or a path never reaches it.
        guard ManPage.isSafeName(name) else { return .missing }

        lock.lock()
        let known = remembered[name]
        lock.unlock()
        if let known { return known }

        guard let outcome = run(name) else { return .failed("man could not be run") }
        if outcome.timedOut { return .failed("man took too long") }

        let result: Result
        if outcome.status != 0 {
            result = .missing
        } else if ManPage.looksLikePage(outcome.output), let excerpt = ManPage.excerpt(fromRaw: outcome.output, limit: limit) {
            result = .found(excerpt)
        } else {
            // Nothing, or a message from man and not a page.
            result = .missing
        }

        // Found and missing are answers; a failure is not, and is tried again.
        lock.lock()
        remembered[name] = result
        lock.unlock()
        return result
    }
}
