import SwiftUI
import AppKit

/// What the quick reference strip shows: the program, and the hints in the
/// order they matter. Worked out from `ActiveProgram` and the catalogs; the
/// view only draws it.
struct QuickReferenceContent {
    enum Source: Equatable {
        /// What is in front of the focused terminal.
        case terminal(ActiveProgram)
        /// A command typed in the composer's input.
        case composer(ActiveProgram.TypedCommand)
    }

    let source: Source
    /// The program's name, as the badge at the strip's start shows it.
    let badge: String
    var hints: [QuickReferenceHint]
    /// The catalog's sections the full list shows.
    var sections: [ProgramKeySection]
    /// For a command being typed: every flag or subcommand there is for it.
    var commandEntries: [SpecEntry] = []
    /// The command being typed, for opening its Cheatsheet page.
    var command: String?
    /// A word after the hints, when there are none to click.
    var note: String?

    var hasFullList: Bool { !sections.isEmpty || !commandEntries.isEmpty }

    /// Changes whenever what is shown does: the cross-fade's key.
    var id: String { badge + "|" + hints.map(\.id).joined(separator: ",") }

    /// The shell's keys, which the strip shows at a prompt. A remote session
    /// adds ssh's way out, which matters most when the far end stops answering.
    static func shell(remote: Bool, source: Source) -> QuickReferenceContent {
        var content = catalog(.shell, badge: remote ? "ssh" : "shell", source: source)
        if remote, let disconnect = ProgramKeyCatalog.entry(id: "ssh.disconnect") {
            content.hints.append(QuickReferenceHint(disconnect))
            content.sections.append(.ssh)
        }
        return content
    }

    /// `isTool` for a bundled tool's panel, which is the program itself: there
    /// is no shell behind it to suspend it to.
    static func make(
        program: ActiveProgram,
        composer: ActiveProgram.TypedCommand?,
        isRunning: Bool,
        isTool: Bool
    ) -> QuickReferenceContent {
        if let composer, let fromComposer = typing(composer, source: .composer(composer)) {
            return fromComposer
        }
        let source = Source.terminal(program)
        guard isRunning else {
            return QuickReferenceContent(source: source, badge: "ended", hints: [], sections: [],
                                         note: "Nothing is running in this terminal")
        }
        switch program {
        case .program(let section, let name):
            return catalog(section, badge: name, source: source)
        case .shell(let remote):
            return shell(remote: remote, source: source)
        case .typing(let typed):
            return typing(typed, source: source) ?? shell(remote: false, source: source)
        case .running(let name):
            // Keys no program can miss: they are the terminal's own. Not for a
            // tool's panel, where ⌃Z would leave the panel holding a stopped
            // program and no shell to bring it back.
            let hints = isTool ? [] : ["shell.interrupt", "shell.suspend", "shell.endInput"]
                .compactMap(ProgramKeyCatalog.entry(id:))
                .map(QuickReferenceHint.init)
            return QuickReferenceContent(source: source, badge: name ?? "running", hints: hints, sections: [],
                                         note: "No keys listed for it")
        }
    }

    private static func catalog(_ section: ProgramKeySection, badge: String, source: Source) -> QuickReferenceContent {
        QuickReferenceContent(
            source: source,
            badge: badge,
            hints: ProgramKeyCatalog.strip(for: section).map(QuickReferenceHint.init),
            sections: [section]
        )
    }

    /// A command's flags, or its subcommands until one is typed, from the
    /// composer's own completion table.
    private static func typing(_ typed: ActiveProgram.TypedCommand, source: Source) -> QuickReferenceContent? {
        guard let spec = CommandSpecs.spec(named: typed.command) else { return nil }
        let subcommand = typed.subcommand.flatMap { spec.subcommand(named: $0) }
        let entries: [SpecEntry]
        if let subcommand {
            entries = spec.options(after: subcommand)
        } else {
            entries = spec.hasSubcommands ? spec.subcommands : spec.options
        }
        guard !entries.isEmpty else { return nil }
        let badge = [typed.command, subcommand?.names.first].compactMap { $0 }.joined(separator: " ")
        return QuickReferenceContent(
            source: source,
            badge: badge,
            hints: entries.compactMap(QuickReferenceHint.init(spec:)),
            sections: [],
            commandEntries: entries,
            command: typed.command
        )
    }
}

/// One hint in the strip: a key or a flag, and a word on what it does.
struct QuickReferenceHint: Identifiable {
    enum Action: Equatable {
        /// Typed into the program as it is.
        case keys(String)
        /// Added to the command line being typed, as a word of its own.
        case word(String)
    }

    let id: String
    let caps: [String]
    let label: String
    let help: String
    let action: Action?

    init(_ entry: ProgramKeyEntry) {
        let way = entry.stripWay
        id = entry.id
        caps = entry.ways.indices.contains(way) ? entry.ways[way] : []
        label = entry.short
        let what = [entry.title, entry.detail].compactMap { $0 }.joined(separator: " — ")
        let typed = entry.typed(way: way)
        help = typed == nil ? what : what + "\n" + QuickReferenceWording.clickHelp(for: entry, way: way)
        action = typed.map(Action.keys)
    }

    init?(spec entry: SpecEntry) {
        guard let name = entry.names.first else { return nil }
        id = "spec." + entry.display
        caps = [name]
        label = entry.detail
        help = entry.display + " — " + entry.detail + "\nClick to add it to the line"
        action = .word(name)
    }
}

/// What the strip and its full list say about a click.
enum QuickReferenceWording {
    static func clickHelp(for entry: ProgramKeyEntry, way index: Int) -> String {
        if case .prefix(let prefix) = entry.click {
            let shown = prefix.replacingOccurrences(of: "space", with: "␣")
            return "Click to type \(shown.replacingOccurrences(of: " ", with: "")), then the rest yourself"
        }
        guard entry.ways.indices.contains(index) else { return "" }
        let way = entry.ways[index]
        let typed = way.last == "↩" ? Array(way.dropLast()) : way
        let lead = entry.section.clickLead.isEmpty ? "" : " (after esc, for normal mode)"
        let ending = way.last == "↩" ? ", then press return to go ahead" : ""
        return "Click to type " + typed.joined(separator: " ") + lead + ending
    }
}

/// The command typed in the composer's input, while the input has the
/// keyboard. Its own small object rather than state on the workspace store:
/// every view that watches the store would otherwise redraw at each keystroke.
final class QuickReferenceModel: ObservableObject {
    static let shared = QuickReferenceModel()

    /// Published only when the command, or its subcommand, changes.
    @Published private(set) var composerTyping: ActiveProgram.TypedCommand?

    func noteComposer(text: String, focused: Bool) {
        let typed = focused ? ActiveProgram.typing(in: text) : nil
        if typed != composerTyping { composerTyping = typed }
    }
}

/// The line above the status bar with the keys for what is in front of the
/// focused terminal — Vim's, man's, the shell's at a prompt, a command's flags
/// as it is typed. Follows focus, as the status bar does.
///
/// It stays while the setting is on, whatever runs, so the terminal above it
/// never changes size under a program: a full-screen program redraws when its
/// terminal shrinks, and a row that came and went with each one would make
/// every editor jump just after it opened.
struct QuickReferenceStrip: View {
    /// The status bar's height, so the seam above either one, when it is the
    /// last row, meets the sidebar footer's seam.
    static let height: CGFloat = WindowChrome.bottomStripHeight

    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        if let session = store.focusedSession {
            // The session is its own observable object; the child observes it.
            QuickReferenceSessionStrip(session: session)
                .id(session.id)
        }
    }
}

private struct QuickReferenceSessionStrip: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject private var model = QuickReferenceModel.shared
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID
    @State private var showAll = false

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        let content = QuickReferenceContent.make(
            program: session.activeProgram,
            composer: model.composerTyping,
            isRunning: session.isRunning,
            isTool: session.kind.isTool
        )
        let row = LeadingFitRow(spacing: 16)
        HStack(spacing: 12) {
            Group {
                row {
                    ForEach(content.hints) { hint in
                        HintView(hint: hint, theme: theme, perform: perform(hint, in: content))
                    }
                    if let note = content.note {
                        Text(note)
                            .lineLimit(1)
                            .foregroundStyle(theme.textSecondary.opacity(0.8))
                    }
                }
            }
            .id(content.id)
            .transition(.opacity)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()

            // At the end of the line, where it costs the hints nothing: what
            // is in front, and — when there is more listed for it than fits —
            // the way to the rest.
            ProgramButton(name: content.badge, theme: theme, opensList: content.hasFullList) {
                showAll.toggle()
            }
            .popover(isPresented: $showAll, arrowEdge: .top) {
                QuickReferenceFullList(
                    content: content,
                    run: { hintAction in
                        showAll = false
                        run(hintAction, in: content)
                    },
                    openCheatsheet: cheatsheetOpener(for: content)
                )
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(theme.textSecondary)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: QuickReferenceStrip.height)
        .animation(Motion.hover, value: content.id)
        // Focus moving here, or the setting just switched on: what is in
        // front may have changed while nothing was looking.
        .onAppear { session.refreshActiveProgram() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick reference for \(content.badge)")
    }

    /// Opens the Cheatsheet on the command being typed, found by its name so
    /// its page is the first in the list.
    private func cheatsheetOpener(for content: QuickReferenceContent) -> (() -> Void)? {
        guard let command = content.command else { return nil }
        return {
            showAll = false
            CheatsheetStore.shared.query = command
            store.openPanel(.cheatsheet)
        }
    }

    private func perform(_ hint: QuickReferenceHint, in content: QuickReferenceContent) -> (() -> Void)? {
        guard let action = hint.action else { return nil }
        return { run(action, in: content) }
    }

    /// Types a hint's keys into the program, or adds a flag to the command
    /// line — in the composer when that is where it is being typed.
    private func run(_ action: QuickReferenceHint.Action, in content: QuickReferenceContent) {
        switch (action, content.source) {
        case (.keys(let text), .terminal(let program)):
            session.typeProgramKeys(text, expecting: program)
        case (.word(let word), .composer):
            // Added after what is there, with a space between; the composer
            // takes the keyboard, so typing carries on there.
            store.insertIntoComposer(word.hasSuffix("=") ? word : word + " ")
        case (.word(let word), .terminal(let program)):
            let line = session.engine.typedLine ?? ""
            let gap = line.isEmpty || line.hasSuffix(" ") ? "" : " "
            session.typeProgramKeys(gap + word + (word.hasSuffix("=") ? "" : " "), expecting: program)
        case (.keys, .composer):
            break
        }
    }
}

/// The program's name, in a small capsule at the end of the line — and, when
/// more is listed for it than the line shows, the button that opens the rest.
/// Narrow on purpose: it is a label, and every point it takes is one a hint
/// does not get.
private struct ProgramButton: View {
    let name: String
    let theme: Theme
    let opensList: Bool
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        if opensList {
            Button(action: open) {
                capsule.contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .onHover { inside in
                withAnimation(Motion.hover) { hovering = inside }
            }
            .help("All keys for \(name)")
            .accessibilityLabel("All keys for \(name)")
        } else {
            capsule
                .help("What is in front of the focused terminal")
                .accessibilityLabel(name)
        }
    }

    private var capsule: some View {
        HStack(spacing: 3) {
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 72)
            if opensList {
                Image(systemName: "chevron.up")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(theme.textPrimary)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .fixedSize()
        .background(Capsule().fill(hovering ? theme.surfaceHover : theme.surface))
        .overlay(Capsule().strokeBorder(theme.surfaceBorder))
    }
}

/// One hint: its keys as caps and a word on what they do. A button when a
/// click types something, warming under the pointer like the bar's other
/// controls.
private struct HintView: View {
    let hint: QuickReferenceHint
    let theme: Theme
    let perform: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        if let perform {
            Button(action: perform) {
                label
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(hovering ? theme.surfaceHover : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // A click here types into the terminal; it must not take the
            // keyboard from it on the way.
            .focusable(false)
            .onHover { inside in
                withAnimation(Motion.hover) { hovering = inside }
            }
            .help(hint.help)
            .accessibilityLabel(hint.label)
            .accessibilityHint("Types " + hint.caps.joined(separator: " then "))
        } else {
            label
                .padding(.horizontal, 4)
                .help(hint.help)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(hint.label + ": " + hint.caps.joined(separator: " then "))
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(Array(hint.caps.enumerated()), id: \.offset) { _, cap in
                    KeyCap(symbol: cap, theme: theme, compact: true, tintsModifiers: true)
                }
            }
            // The keys never give way: shown cut down they read as "…", which
            // says nothing. Only the words beside them may be shortened.
            .fixedSize()
            .layoutPriority(1)
            Text(hint.label)
                .lineLimit(1)
                .truncationMode(.tail)
                // A flag's description can run to a sentence; the strip has
                // room for a few words of each.
                .frame(maxWidth: 170, alignment: .leading)
        }
    }
}

/// What each modifier's colour means, in the colours the caps use.
private struct ModifierLegend: View {
    let theme: Theme

    var body: some View {
        HStack(spacing: 14) {
            ForEach(ModifierGlyph.allCases) { modifier in
                HStack(spacing: 4) {
                    Text(String(modifier.rawValue))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(modifier.tint)
                    Text(modifier == .option ? "Option (Meta)" : modifier.name)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(modifier.name)
            }
            Spacer(minLength: 0)
        }
    }
}

/// A row that places its subviews in order and leaves out every one from the
/// first that would not fit — the strip's hints are in the order they matter,
/// so a narrow window keeps the ones that matter most. Nothing wraps or
/// scrolls.
private struct LeadingFitRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let available = proposal.width ?? .infinity
        var used: CGFloat = 0
        var height: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let end = used + (index > 0 ? spacing : 0) + size.width
            if end > available { break }
            used = end
            height = max(height, size.height)
        }
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var fits = true
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let start = x + (index > 0 ? spacing : 0)
            if fits, start + size.width <= bounds.maxX + 0.5 {
                // Asked for nothing in particular, as when it was measured, so
                // it takes the size it measured at rather than a rounded copy
                // of it that can come out a fraction short.
                subview.place(at: CGPoint(x: start, y: bounds.midY), anchor: .leading, proposal: .unspecified)
                x = start + size.width
            } else {
                // Everything after the first that does not fit goes too, so a
                // short hint never jumps ahead of a longer, earlier one. Placed
                // far outside the clipped row, where it is neither seen nor
                // clicked.
                fits = false
                subview.place(at: CGPoint(x: bounds.maxX + 10_000, y: bounds.midY), anchor: .leading,
                              proposal: .unspecified)
            }
        }
    }
}

/// Everything listed for what the strip shows, opened from the program's name
/// at the end of the line. A click types a key as the strip does, and closes
/// the list so typing goes back to the terminal.
private struct QuickReferenceFullList: View {
    let content: QuickReferenceContent
    let run: (QuickReferenceHint.Action) -> Void
    let openCheatsheet: (() -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        VStack(spacing: 0) {
            if !content.sections.isEmpty {
                ModifierLegend(theme: theme)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                FadedDivider()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(content.sections) { section in
                        header(section.title, note: section.note, theme: theme)
                        ForEach(ProgramKeyCatalog.entries(in: section)) { entry in
                            ProgramKeyRow(command: entry, onType: { index in
                                if let text = entry.typed(way: index) { run(.keys(text)) }
                            }, tintsModifiers: true)
                        }
                    }
                    if !content.commandEntries.isEmpty {
                        header(content.badge, note: "From the composer's completion list, for the version macOS ships. Click one to add it to the line.",
                               theme: theme)
                        ForEach(Array(content.commandEntries.enumerated()), id: \.offset) { _, entry in
                            specRow(entry, theme: theme)
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            if let openCheatsheet {
                FadedDivider()
                HStack {
                    Spacer()
                    Button("Examples in the Cheatsheet", action: openCheatsheet)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .frame(width: 460, height: 420)
        .background(theme.background)
    }

    private func header(_ title: String, note: String?, theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            if let note {
                Text(note)
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(theme.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func specRow(_ entry: SpecEntry, theme: Theme) -> some View {
        Button {
            if let name = entry.names.first { run(.word(name)) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(entry.display)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
                Spacer(minLength: 12)
                Text(entry.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("Add \(entry.names.first ?? entry.display) to the line")
    }
}
