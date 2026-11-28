import Foundation

// MARK: - Model

/// One thing done in a composer session: a command sent, or a message in a
/// chat.
struct ComposerLogEvent: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var text: String
    /// Where a command went — the terminal's name — or who said a message:
    /// "You" or "AI". Nil for the composer's own shell, which is the session.
    var who: String?
}

/// Everything that happened in one stretch of composer use, from when it began
/// until it was closed: a run of the composer's own shell, the commands sent to
/// other terminals while the app was open, or one AI conversation.
struct ComposerLogSession: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        /// The composer's own shell, with what it printed once it ended.
        case shell
        /// Commands the composer sent to terminals in view.
        case terminals
        /// A conversation with the AI.
        case assistant

        var icon: String {
            switch self {
            case .shell: return "text.cursor"
            case .terminals: return "terminal"
            case .assistant: return "sparkles"
            }
        }

        var label: String {
            switch self {
            case .shell: return "Composer shell"
            case .terminals: return "Terminals"
            case .assistant: return "AI"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    var title: String
    var startedAt: Date
    /// Nil while it is still going.
    var endedAt: Date?
    var events: [ComposerLogEvent] = []
    /// Whether what the shell printed was kept, in a file of its own. Kept apart
    /// so the list loads without reading every session's output.
    var hasOutput = false
    /// Set on a session recorded by a build that names a terminal after a line
    /// only when its shell was reading it (`TypedCommand`). An older one's
    /// events name terminals by titles that may be a password typed at a sudo
    /// or ssh prompt, so those names are dropped when it is read.
    var terminalNamesVetted: Bool?

    var isLive: Bool { endedAt == nil }
}

// MARK: - Store

/// A record of what was done in the composer, kept on this Mac so a session can
/// be looked at again after it ends.
///
/// This is the one place the composer's input reaches disk. The arrow-key and
/// suggestion history stays in memory because a line typed there is as likely
/// to hold a token as a `ls`, and so can this. Which is why it is built the way
/// it is: it can be switched off (Settings → Composer → History), what it keeps
/// goes through the same masking as text sent to an assistant, and it is limited
/// in size and age. Masking is best effort — it knows the shapes of common
/// secrets, not every secret — so none of this claims that nothing sensitive is
/// kept.
///
/// Like transcripts and chats it is kept out of the workspace archive and its
/// files are readable by the owner alone.
final class ComposerLog: ObservableObject {
    /// Newest first.
    @Published private(set) var sessions: [ComposerLogSession] = []

    /// The most one session keeps; the oldest events go first.
    static let maxEventsPerSession = 1_000
    /// The longest a single command or message is kept.
    static let maxEventCharacters = 4_000
    /// What the shell printed, kept from the end of it.
    static let maxOutputBytes = 128 * 1024
    /// Sessions kept, whatever their age.
    static let maxSessions = 400

    /// Sessions still going, by the key whoever is recording gave them.
    private var open: [String: UUID] = [:]
    private var dirty: Set<UUID> = []
    private var pendingSave: DispatchWorkItem?

    private static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base
            .appendingPathComponent("iTERMiNAL", isDirectory: true)
            .appendingPathComponent("ComposerLog", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }()

    private static func sessionURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private static func outputURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).txt")
    }

    init() {
        sessions = Self.loadAll()
        forgetUnvettedTerminalNames()
        prune()
    }

    /// Drops the terminal names an older build recorded with commands sent to
    /// terminals, and writes those sessions again without them. Such a name was
    /// the terminal's title, which could be a password taken for a command
    /// (see `TypedCommand`). The commands are kept: they are what was typed in
    /// the composer, not a title. A session read back has ended, so nothing is
    /// added to one of these again.
    private func forgetUnvettedTerminalNames() {
        for index in sessions.indices
        where sessions[index].kind == .terminals
            && sessions[index].terminalNamesVetted != true
            && sessions[index].events.contains(where: { $0.who != nil }) {
            for event in sessions[index].events.indices {
                sessions[index].events[event].who = nil
            }
            dirty.insert(sessions[index].id)
        }
        if !dirty.isEmpty { saveNow() }
    }

    // MARK: Recording

    /// Adds `text` to the session `key` names, starting one if none is going.
    /// Does nothing while the log is switched off.
    func record(
        _ text: String,
        who: String? = nil,
        in key: String,
        kind: ComposerLogSession.Kind,
        title: String
    ) {
        guard AppSettings.shared.composerKeepHistory else { return }
        let cleaned = Self.clean(text)
        guard !cleaned.isEmpty else { return }

        let id: UUID
        if let existing = open[key], sessions.contains(where: { $0.id == existing }) {
            id = existing
        } else {
            let session = ComposerLogSession(kind: kind, title: title, startedAt: Date(), terminalNamesVetted: true)
            sessions.insert(session, at: 0)
            open[key] = session.id
            id = session.id
        }
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].events.append(ComposerLogEvent(date: Date(), text: cleaned, who: who))
        let overflow = sessions[index].events.count - Self.maxEventsPerSession
        if overflow > 0 { sessions[index].events.removeFirst(overflow) }
        dirty.insert(id)
        scheduleSave()
    }

    /// Ends the session `key` names, keeping `output` — what a shell printed —
    /// with it. Nothing happens if there is no such session going.
    func close(_ key: String, output: String? = nil) {
        guard let id = open.removeValue(forKey: key),
              let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].endedAt = Date()
        if let output, AppSettings.shared.composerKeepHistory {
            let cleaned = Self.cleanOutput(output)
            if !cleaned.isEmpty, Self.write(Data(cleaned.utf8), to: Self.outputURL(id)) {
                sessions[index].hasOutput = true
            }
        }
        dirty.insert(id)
        // An ending is worth keeping at once, not a second from now.
        saveNow()
    }

    /// Ends everything still going. At quit, where a debounced save would never
    /// fire.
    func closeAll() {
        for key in Array(open.keys) { close(key) }
        saveNow()
    }

    // MARK: Reading and removing

    /// What a shell printed, once it ended.
    func output(for id: UUID) -> String? {
        try? String(contentsOf: Self.outputURL(id), encoding: .utf8)
    }

    func delete(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        open = open.filter { $0.value != id }
        dirty.remove(id)
        try? FileManager.default.removeItem(at: Self.sessionURL(id))
        try? FileManager.default.removeItem(at: Self.outputURL(id))
    }

    /// Removes everything, including sessions still going: what is said next
    /// starts a new one.
    func clearAll() {
        pendingSave?.cancel()
        pendingSave = nil
        dirty.removeAll()
        open.removeAll()
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        for file in files { try? FileManager.default.removeItem(at: file) }
        sessions = []
    }

    /// A session as plain text, for copying out.
    func text(for session: ComposerLogSession) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        var lines = ["\(session.kind.label) — \(session.title)", "Started \(formatter.string(from: session.startedAt))"]
        if let ended = session.endedAt { lines.append("Ended \(formatter.string(from: ended))") }
        lines.append("")
        let time = DateFormatter()
        time.dateStyle = .none
        time.timeStyle = .medium
        for event in session.events {
            let who = event.who.map { "\($0): " } ?? ""
            lines.append("[\(time.string(from: event.date))] \(who)\(event.text)")
        }
        if session.hasOutput, let output = output(for: session.id) {
            lines.append("")
            lines.append("— output —")
            lines.append(output)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Retention

    /// Drops sessions older than the retention setting, and any beyond the cap.
    /// Never one that is still going.
    func prune() {
        let days = AppSettings.shared.composerHistoryDays
        let liveIDs = Set(open.values)
        var doomed: [UUID] = []
        if days > 0, let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) {
            doomed += sessions
                .filter { !liveIDs.contains($0.id) && ($0.endedAt ?? $0.startedAt) < cutoff }
                .map(\.id)
        }
        let remaining = sessions.filter { !doomed.contains($0.id) }
        if remaining.count > Self.maxSessions {
            doomed += remaining.dropFirst(Self.maxSessions)
                .filter { !liveIDs.contains($0.id) }
                .map(\.id)
        }
        doomed.forEach { delete($0) }
    }

    // MARK: Cleaning

    /// Masks what looks like a credential and cuts the text to length.
    private static func clean(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let masked = SecretRedactor.redact(String(trimmed.prefix(maxEventCharacters)))
        return masked
    }

    /// The same for what a shell printed, from the end of it, which is where
    /// the last thing that happened is.
    private static func cleanOutput(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return SecretRedactor.redact(String(trimmed.suffix(maxOutputBytes)))
    }

    // MARK: Disk

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// Writes what has changed. Called on a session's end and at quit.
    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for id in dirty {
            guard let session = sessions.first(where: { $0.id == id }),
                  let data = try? encoder.encode(session) else { continue }
            _ = Self.write(data, to: Self.sessionURL(id))
        }
        dirty.removeAll()
    }

    private static func write(_ data: Data, to url: URL) -> Bool {
        do {
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            NSLog("Failed to save composer history: \(error.localizedDescription)")
            return false
        }
    }

    /// Reads every saved session. One that was still going when the app last
    /// stopped — a crash, a force-quit — is ended at its last event.
    private static func loadAll() -> [ComposerLogSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loaded: [ComposerLogSession] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  var session = try? decoder.decode(ComposerLogSession.self, from: data) else { continue }
            if session.endedAt == nil {
                session.endedAt = session.events.last?.date ?? session.startedAt
            }
            loaded.append(session)
        }
        return loaded.sorted { $0.startedAt > $1.startedAt }
    }
}
