import SwiftUI
import AppKit

/// The composer's session history: every stretch of composer use that was kept,
/// newest first and grouped by day, to look back at.
///
/// A session is one run of the composer's own shell (with what it printed once
/// it ended), the commands sent to terminals while the app was open, or one AI
/// conversation. See `ComposerLog` for what is kept, for how long, and what is
/// masked on the way in.
struct ComposerHistoryView: View {
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        // The log is read from disk the first time it is asked for, so it is
        // asked for here, and the content watches it.
        ComposerHistoryContent(log: store.composerLog)
    }
}

private struct ComposerHistoryContent: View {
    @ObservedObject var log: ComposerLog

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var expanded: Set<UUID> = []
    @State private var confirmingClear = false

    private enum Filter: String, CaseIterable, Identifiable {
        case all, shell, terminals, assistant

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "All"
            case .shell: return "Shell"
            case .terminals: return "Terminals"
            case .assistant: return "AI"
            }
        }

        func includes(_ kind: ComposerLogSession.Kind) -> Bool {
            switch self {
            case .all: return true
            case .shell: return kind == .shell
            case .terminals: return kind == .terminals
            case .assistant: return kind == .assistant
            }
        }
    }

    private struct DayGroup: Identifiable {
        let day: Date
        let sessions: [ComposerLogSession]
        var id: Date { day }
    }

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        let groups = dayGroups(of: visibleSessions())
        VStack(spacing: 0) {
            header(theme: theme)
            FadedDivider()

            if !settings.composerKeepHistory {
                Label("History is off — nothing new is being recorded.", systemImage: "pause.circle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
            }

            if groups.isEmpty {
                emptyState(theme: theme)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups) { group in
                            Text(dayTitle(group.day))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(theme.textSecondary)
                                .padding(.horizontal, 20)
                                .padding(.top, 14)
                                .padding(.bottom, 4)
                            ForEach(group.sessions) { session in
                                HistorySessionRow(
                                    session: session,
                                    log: log,
                                    isExpanded: expanded.contains(session.id) || !query.isEmpty
                                ) {
                                    toggle(session.id)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }

            FadedDivider()
            footer(theme: theme)
        }
        .frame(width: 660, height: 580)
        .background(theme.background)
        .confirmationDialog("Delete all composer history?", isPresented: $confirmingClear) {
            Button("Delete All", role: .destructive) { log.clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every kept session and what its shell printed is removed from this Mac. This can't be undone.")
        }
    }

    // MARK: Parts

    private func header(theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Composer history")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 10) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                    TextField("Search commands and messages", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.surface.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.surfaceBorder))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func emptyState(theme: Theme) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 26))
                .foregroundStyle(theme.textSecondary)
            Text(log.sessions.isEmpty ? "Nothing here yet" : "Nothing matches")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.textPrimary)
            Text(log.sessions.isEmpty
                 ? "Run a command in the composer, or talk to the AI, and the session shows up here."
                 : "Try another search, or show all kinds of session.")
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func footer(theme: Theme) -> some View {
        HStack(spacing: 10) {
            Text(footerText)
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
            Spacer()
            Button("Delete All…", role: .destructive) { confirmingClear = true }
                .disabled(log.sessions.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var footerText: String {
        let count = log.sessions.count
        let noun = count == 1 ? "session" : "sessions"
        let keep = settings.composerHistoryDays == 0
            ? "kept until deleted"
            : "kept for \(settings.composerHistoryDays) days"
        return "\(count) \(noun) · \(keep) · stored on this Mac"
    }

    // MARK: Data

    private func visibleSessions() -> [ComposerLogSession] {
        log.sessions.filter { session in
            guard filter.includes(session.kind) else { return false }
            if query.isEmpty { return true }
            if session.title.localizedCaseInsensitiveContains(query) { return true }
            return session.events.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }
    }

    private func dayGroups(of sessions: [ComposerLogSession]) -> [DayGroup] {
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: sessions) { calendar.startOfDay(for: $0.startedAt) }
        return byDay.keys.sorted(by: >).map { DayGroup(day: $0, sessions: byDay[$0] ?? []) }
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .complete, time: .omitted)
    }

    private func toggle(_ id: UUID) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }
}

// MARK: - Row

/// One session: when it was and how much happened, opening to what was said and
/// — for a shell — what it printed.
private struct HistorySessionRow: View {
    let session: ComposerLogSession
    let log: ComposerLog
    let isExpanded: Bool
    let onToggle: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID
    @State private var hovering = false
    @State private var showOutput = false
    @State private var output: String?

    /// How many events an open session lists; the rest are in Copy.
    private static let shownEvents = 200
    /// How many lines of output it shows.
    private static let shownOutputLines = 300

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onToggle) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 10)
                        Image(systemName: session.kind.icon)
                            .font(.system(size: 11))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(session.title)
                                .font(.system(size: 12.5, weight: .medium))
                                .lineLimit(1)
                            Text(summary)
                                .font(.system(size: 11))
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if session.isLive {
                    Circle()
                        .fill(settings.accentColor)
                        .frame(width: 6, height: 6)
                        .help("Still going")
                }

                RowIconButton(icon: "doc.on.doc", help: "Copy this session", theme: theme) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.text(for: session), forType: .string)
                }
                RowIconButton(icon: "trash", help: "Delete this session", theme: theme) {
                    log.delete(session.id)
                }
            }
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(theme.surface.opacity(hovering ? 0.5 : 0))
            .onHover { hovering = $0 }

            if isExpanded {
                detail(theme: theme)
                    .padding(.leading, 56)
                    .padding(.trailing, 20)
                    .padding(.bottom, 10)
            }
        }
    }

    // MARK: Detail

    private func detail(theme: Theme) -> some View {
        let shown = Array(session.events.suffix(Self.shownEvents))
        let hidden = session.events.count - shown.count
        return VStack(alignment: .leading, spacing: 6) {
            if hidden > 0 {
                Text("\(hidden) earlier not shown — Copy has everything.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
            }
            ForEach(shown) { event in
                eventRow(event, theme: theme)
            }
            if session.hasOutput {
                outputBlock(theme: theme)
            }
        }
    }

    private func eventRow(_ event: ComposerLogEvent, theme: Theme) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(event.date.formatted(date: .omitted, time: .standard))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 66, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                if let who = event.who {
                    Text(who)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                }
                Text(event.text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func outputBlock(theme: Theme) -> some View {
        Button(showOutput ? "Hide output" : "Show output") {
            if output == nil { output = log.output(for: session.id) ?? "" }
            showOutput.toggle()
        }
        .buttonStyle(.link)
        .font(.system(size: 11.5))

        if showOutput {
            ScrollView {
                Text(outputTail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 220)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.surface.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.surfaceBorder))
        }
    }

    /// The end of what the shell printed: the last thing that happened is there.
    private var outputTail: String {
        guard let output, !output.isEmpty else { return "Nothing was kept." }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > Self.shownOutputLines else { return output }
        let tail = lines.suffix(Self.shownOutputLines).joined(separator: "\n")
        return "… (earlier output not shown — Copy has it)\n" + tail
    }

    // MARK: Summary

    /// "14:02 – 14:37 · 12 commands".
    private var summary: String {
        let start = session.startedAt.formatted(date: .omitted, time: .shortened)
        var when = start
        if let ended = session.endedAt {
            let end = ended.formatted(date: .omitted, time: .shortened)
            if end != start { when = "\(start) – \(end)" }
        } else {
            when = "\(start) – now"
        }
        let count = session.events.count
        let noun: String
        switch session.kind {
        case .assistant: noun = count == 1 ? "message" : "messages"
        case .shell, .terminals: noun = count == 1 ? "command" : "commands"
        }
        return "\(when) · \(count) \(noun)"
    }
}
