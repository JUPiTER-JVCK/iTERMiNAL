import SwiftUI
import AppKit

struct ChatMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable {
        case user
        case assistant
        /// Something went wrong asking. Shown, never sent back to the model,
        /// never saved.
        case error
    }

    var id = UUID()
    var role: Role
    var text: String
    var date = Date()
}

/// The composer's chat with the AI model: one conversation per space, kept on
/// this Mac in `Chats/<space id>.json` with owner-only permissions.
///
/// Like notes and transcripts it is not in the workspace snapshot or an
/// export: it holds whatever was typed, which is the least predictable content
/// in the app. Nothing here runs anything — a reply is text.
final class ComposerChatModel: ObservableObject {
    let workspaceID: UUID
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isReplying = false

    /// Plenty to scroll back through without a file that grows for ever.
    static let maxStoredMessages = 200
    /// What is sent back with a new message: the most recent turns, cut to a
    /// size a model's window and a person's bill can both live with.
    static let maxContextMessages = 30
    static let maxContextCharacters = 24_000

    private var task: Task<Void, Never>?
    private var pendingSave: DispatchWorkItem?

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("iTERMiNAL", isDirectory: true)
            .appendingPathComponent("Chats", isDirectory: true)
    }

    private static func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    init(workspaceID: UUID) {
        self.workspaceID = workspaceID
        if let data = try? Data(contentsOf: Self.fileURL(for: workspaceID)) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let saved = try? decoder.decode([ChatMessage].self, from: data) {
                messages = saved.filter { $0.role != .error }
            }
        }
    }

    static func deleteFile(for id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    // MARK: Sending

    /// Adds what the person typed and asks the model, with the conversation so
    /// far. Only the typed text and earlier turns are sent — never terminal
    /// output — plus the folder, branch and space name when Settings → AI has
    /// those switched on.
    func send(_ text: String, settings: AppSettings, store: WorkspaceStore) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isReplying else { return }
        append(ChatMessage(role: .user, text: trimmed))

        let service = AssistantServiceProvider.current
        guard service.isConfigured else {
            append(ChatMessage(role: .error, text: "No AI model is set up yet. Add a provider in Settings → AI."))
            return
        }

        let session = store.focusedSession ?? store.composerSession
        var lines = [Self.systemPrompt]
        if settings.assistantIncludeWorkspace, let name = store.currentWorkspace?.name { lines.append("Space: \(name)") }
        if settings.assistantIncludeCwd, let directory = session?.currentDirectory { lines.append("Working directory: \(directory)") }
        if settings.assistantIncludeGitBranch, let branch = session?.gitBranch { lines.append("Git branch: \(branch)") }
        let system = lines.joined(separator: "\n")
        let history = Self.contextMessages(from: messages)

        isReplying = true
        task = Task { [weak self] in
            do {
                let reply = try await service.chat(system: system, messages: history)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.append(ChatMessage(role: .assistant, text: reply))
                    self?.isReplying = false
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.append(ChatMessage(role: .error, text: error.localizedDescription))
                    self?.isReplying = false
                }
            }
        }
    }

    /// Stops waiting for a reply. The request may still finish on the server;
    /// its answer is dropped.
    func cancel() {
        task?.cancel()
        task = nil
        isReplying = false
    }

    /// Empties the conversation and its file.
    func clear() {
        cancel()
        messages = []
        pendingSave?.cancel()
        pendingSave = nil
        Self.deleteFile(for: workspaceID)
    }

    static let systemPrompt = """
        You are chatting with someone inside a macOS terminal app (iTERMiNAL). \
        Be concise and direct. When you suggest shell commands, put them in a fenced \
        code block, and never claim to have run anything — you cannot; the person \
        decides what goes into a terminal.
        """

    /// The turns to send: the latest ones that fit, errors left out, starting
    /// on a person's message.
    static func contextMessages(from messages: [ChatMessage]) -> [AssistantMessage] {
        var kept: [AssistantMessage] = []
        var characters = 0
        for message in messages.reversed() where message.role != .error {
            if kept.count >= maxContextMessages { break }
            // The newest message always goes, however long.
            if !kept.isEmpty, characters + message.text.count > maxContextCharacters { break }
            characters += message.text.count
            kept.append(AssistantMessage(role: message.role == .user ? "user" : "assistant", content: message.text))
        }
        kept.reverse()
        while let first = kept.first, first.role != "user" { kept.removeFirst() }
        return kept
    }

    // MARK: Saving

    private func append(_ message: ChatMessage) {
        messages.append(message)
        if messages.count > Self.maxStoredMessages {
            messages.removeFirst(messages.count - Self.maxStoredMessages)
        }
        if message.role != .error { scheduleSave() }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// Writes now. Called on quit, where the debounced save would never fire.
    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        let kept = messages.filter { $0.role != .error }
        guard !kept.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(kept) else { return }
        let url = Self.fileURL(for: workspaceID)
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("Failed to save chat: \(error.localizedDescription)")
        }
    }
}

// MARK: - View

/// The chat's transcript, standing where the composer's shell output does.
struct ComposerChatView: View {
    @ObservedObject var chat: ComposerChatModel
    let modelName: String
    let theme: Theme
    let accent: Color

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                Text(modelName.isEmpty ? "AI assistant" : modelName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if chat.isReplying {
                    Button("Stop") { chat.cancel() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                }
                Button {
                    chat.clear()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .disabled(chat.messages.isEmpty)
                .help("Clear this conversation")
            }
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            FadedDivider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if chat.messages.isEmpty && !chat.isReplying {
                            Text("Say something. Replies appear here, and the conversation is kept for this space.")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textSecondary)
                                .padding(.top, 4)
                        }
                        ForEach(chat.messages) { message in
                            bubble(message)
                                .id(message.id)
                        }
                        if chat.isReplying {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Thinking…")
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.textSecondary)
                            }
                            .id("replying")
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: chat.messages.count) { _, _ in scrollToEnd(proxy) }
                .onChange(of: chat.isReplying) { _, _ in scrollToEnd(proxy) }
                .onAppear { scrollToEnd(proxy) }
            }
        }
        .background(theme.background)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if chat.isReplying {
            proxy.scrollTo("replying", anchor: .bottom)
        } else if let last = chat.messages.last {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    @ViewBuilder
    private func bubble(_ message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                ChatText(text: message.text, theme: theme)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(accent.opacity(0.22)))
            }
        case .assistant:
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    ChatText(text: message.text, theme: theme)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.textSecondary.opacity(0.10)))
                Spacer(minLength: 40)
            }
        case .error:
            Label(message.text, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A message's text: ordinary lines with inline Markdown, and fenced code in a
/// monospaced block of its own.
private struct ChatText: View {
    let text: String
    let theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.segments(of: text).enumerated()), id: \.offset) { _, segment in
                if segment.isCode {
                    Text(segment.text)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(theme.textPrimary)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(0.18)))
                } else {
                    Text(Self.attributed(segment.text))
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    struct Segment {
        var text: String
        var isCode: Bool
    }

    /// Splits on ``` fences. An unclosed fence — a reply cut short — is still
    /// shown as code.
    static func segments(of text: String) -> [Segment] {
        var result: [Segment] = []
        for (index, part) in text.components(separatedBy: "```").enumerated() {
            let isCode = index % 2 == 1
            var piece = part
            if isCode, let newline = piece.firstIndex(of: "\n") {
                // The language name after the opening fence.
                let first = piece[..<newline].trimmingCharacters(in: .whitespaces)
                if !first.contains(" ") { piece = String(piece[piece.index(after: newline)...]) }
            }
            piece = isCode
                ? piece.trimmingCharacters(in: .newlines)
                : piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { result.append(Segment(text: piece, isCode: isCode)) }
        }
        return result.isEmpty ? [Segment(text: text, isCode: false)] : result
    }

    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
