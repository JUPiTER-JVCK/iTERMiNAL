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

    /// How the strip is set up around what it shows: which prefix keys are
    /// set, whether the shell's own keys are wanted at a prompt, and which
    /// programs the Cheatsheet has a page for.
    struct Context {
        /// The prefix key the person set, for a multiplexer whose own one it
        /// replaces: tmux's ⌃B, screen's ⌃A.
        var prefixes: [ProgramKeySection: String] = [:]
        var showsShellKeys = true
        var hasCheatsheet: (String) -> Bool = { _ in false }
    }

    let source: Source
    /// The program's name, as the end of the strip shows it.
    let badge: String
    var hints: [QuickReferenceHint]
    /// The catalog's sections the full list shows.
    var sections: [ProgramKeySection]
    /// The prefix key set for a section, when it is not the program's own.
    var prefixes: [ProgramKeySection: String] = [:]
    /// For a command being typed: every flag or subcommand there is for it.
    var commandEntries: [SpecEntry] = []
    /// The command being typed, for opening its Cheatsheet page.
    var command: String?
    /// A program with no keys listed that the Cheatsheet has a page for: its
    /// name opens that page.
    var cheatsheetName: String?
    /// A word after the hints, when there are none to click.
    var note: String?

    var hasFullList: Bool { !sections.isEmpty || !commandEntries.isEmpty }

    /// Changes whenever what is shown does: the cross-fade's key.
    var id: String { badge + "|" + hints.map(\.id).joined(separator: ",") }

    /// `section`'s keys as shown here: with the prefix set swapped in.
    func entries(in section: ProgramKeySection) -> [ProgramKeyEntry] {
        ProgramKeyCatalog.entries(in: section, prefix: prefixes[section])
    }

    /// The shell's keys, which the strip shows at a prompt. A remote session
    /// adds ssh's way out, which matters most when the far end stops answering.
    static func shell(remote: Bool, source: Source, context: Context) -> QuickReferenceContent {
        var content = catalog(.shell, badge: remote ? "ssh" : "shell", source: source, context: context)
        if !context.showsShellKeys { content.hints = [] }
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
        isTool: Bool,
        context: Context = Context()
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
        case .program(let section, let name, let host):
            var content = catalog(section, badge: name, source: source, context: context)
            if let host {
                // The program in a tmux pane: its keys in the strip, and
                // tmux's beside them in the full list.
                content = QuickReferenceContent(
                    source: source, badge: "\(name) in \(host.badge)", hints: content.hints,
                    sections: [section, host], prefixes: context.prefixes
                )
            }
            return content
        case .shell(let remote):
            return shell(remote: remote, source: source, context: context)
        case .typing(let typed):
            return typing(typed, source: source) ?? shell(remote: false, source: source, context: context)
        case .running(let name):
            // Keys no program can miss: they are the terminal's own. Not for a
            // tool's panel, where ⌃Z would leave the panel holding a stopped
            // program and no shell to bring it back.
            let hints = isTool ? [] : ["shell.interrupt", "shell.suspend", "shell.endInput"]
                .compactMap(ProgramKeyCatalog.entry(id:))
                .map(QuickReferenceHint.init)
            let cheatsheet = name.flatMap { context.hasCheatsheet($0) ? $0 : nil }
            return QuickReferenceContent(
                source: source, badge: name ?? "running", hints: hints, sections: [],
                cheatsheetName: cheatsheet,
                note: cheatsheet == nil ? "No keys listed for it" : "No keys listed — its name opens the Cheatsheet"
            )
        }
    }

    private static func catalog(
        _ section: ProgramKeySection, badge: String, source: Source, context: Context
    ) -> QuickReferenceContent {
        QuickReferenceContent(
            source: source,
            badge: badge,
            hints: ProgramKeyCatalog.strip(for: section, prefix: context.prefixes[section]).map(QuickReferenceHint.init),
            sections: [section],
            prefixes: context.prefixes
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
        let lead = entry.section.clickLead.isEmpty ? "" : " (after esc, for normal mode)"
        if case .prefix(let prefix) = entry.click {
            let shown = prefix.replacingOccurrences(of: "space", with: "␣").replacingOccurrences(of: " ", with: "")
            return "Click to type \(shown)\(lead), then the rest yourself"
        }
        guard entry.ways.indices.contains(index) else { return "" }
        let way = entry.ways[index]
        let typed = way.last == "↩" ? Array(way.dropLast()) : way
        let ending = way.last == "↩" ? ", then press return to go ahead" : ""
        return "Click to type " + typed.joined(separator: " ") + lead + ending
    }
}

/// The command typed in the composer's input, while the input has the
/// keyboard and is a shell's. Its own small object rather than state on the
/// workspace store: every view that watches the store would otherwise redraw
/// at each keystroke.
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
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID
    @State private var showAll = false
    /// Each hint's width, by its id, from the copy of the row that is never
    /// drawn (`HintMeasure`); and the width there is for them.
    @State private var hintWidths: [String: CGFloat] = [:]
    @State private var hintRoom: CGFloat = 0

    static let hintSpacing: CGFloat = 16
    /// The note's key among the widths, which no hint's id can be.
    static let noteWidthKey = "\u{0}note"

    private var content: QuickReferenceContent {
        var context = QuickReferenceContent.Context()
        if let prefix = session.tmuxPrefix { context.prefixes[.tmux] = prefix }
        if let escape = session.screenEscape { context.prefixes[.screen] = escape }
        context.showsShellKeys = settings.showQuickReferenceShellKeys
        context.hasCheatsheet = { CheatsheetStore.shared.library.program(named: $0) != nil }
        return QuickReferenceContent.make(
            program: session.activeProgram,
            composer: model.composerTyping,
            isRunning: session.isRunning,
            isTool: session.kind.isTool,
            context: context
        )
    }

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        let content = self.content
        HStack(spacing: 12) {
            hints(content, theme: theme)
                .id(content.id)
                .transition(.opacity)
                .clipped()

            // At the end of the line, where it costs the hints nothing: what
            // is in front, and — when there is more to see for it — the way
            // to the rest.
            ProgramButton(
                name: content.badge, theme: theme,
                action: content.hasFullList || content.cheatsheetName != nil ? { open(content) } : nil,
                help: content.hasFullList ? "All keys for \(content.badge) (⌥⌘/)"
                    : "Examples for \(content.badge) in the Cheatsheet"
            )
            .popover(isPresented: $showAll, arrowEdge: .top) {
                QuickReferenceFullList(
                    content: content,
                    run: { hintAction in
                        showAll = false
                        run(hintAction, in: content)
                    },
                    openCheatsheet: cheatsheetOpener(for: content.command)
                )
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(theme.textSecondary)
        .lineLimit(1)
        // 10, not the status bar's 14: a hint's own 4 of padding, for its
        // hover, brings its first key onto the status bar's first icon.
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .frame(height: QuickReferenceStrip.height)
        .animation(Motion.hover, value: content.id)
        // Focus moving here, or the setting just switched on: what is in
        // front may have changed while nothing was looking.
        .onAppear {
            session.refreshActiveProgram()
            if store.quickReferenceListPending { DispatchQueue.main.async { open(self.content) } }
        }
        .onChange(of: store.quickReferenceListPending) { _, pending in
            if pending { open(self.content) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick reference for \(content.badge)")
    }

    /// The hints that fit, in the order they matter, leaving out every one
    /// from the first that would not — so a narrow window keeps the ones that
    /// matter most, nothing wraps or scrolls, and nothing left out is still
    /// there for VoiceOver to read.
    ///
    /// One row, of only the hints that fit, built once. How many that is comes
    /// from each hint's width, measured on a copy of the row that is never
    /// drawn and that VoiceOver does not see (`QuickReferenceFit`): a hint not
    /// yet measured is not shown, so for a frame after the hints change the
    /// line may be short, inside the cross-fade.
    private func hints(_ content: QuickReferenceContent, theme: Theme) -> some View {
        let count = QuickReferenceFit.count(
            widths: content.hints.map { hintWidths[$0.id] },
            hasNote: content.note != nil,
            noteWidth: hintWidths[Self.noteWidthKey],
            spacing: Self.hintSpacing,
            room: hintRoom
        )
        return HStack(spacing: Self.hintSpacing) {
            ForEach(content.hints.prefix(count)) { hint in
                HintView(hint: hint, theme: theme, perform: perform(hint, in: content))
            }
            if count == content.hints.count, let note = content.note {
                Text(note)
                    .lineLimit(1)
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .leading) {
            HintMeasure(content: content, theme: theme, spacing: Self.hintSpacing)
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: HintRoomKey.self, value: proxy.size.width)
            }
        }
        // Merged, not replaced: through a cross-fade the old row and the new
        // one both say what they measured, and a hint seen before keeps its
        // width for when it comes back.
        .onPreferenceChange(HintWidthsKey.self) { widths in hintWidths.merge(widths) { $1 } }
        .onPreferenceChange(HintRoomKey.self) { hintRoom = $0 }
    }

    /// The program's name was clicked, or ⌥⌘/ pressed: the full list, or for
    /// a program with none, its Cheatsheet page.
    private func open(_ content: QuickReferenceContent) {
        if store.quickReferenceListPending { store.quickReferenceListPending = false }
        if content.hasFullList {
            showAll = true
        } else if let name = content.cheatsheetName {
            cheatsheetOpener(for: name)?()
        }
    }

    /// Opens the Cheatsheet on a program, found by its name so its page is the
    /// first in the list.
    private func cheatsheetOpener(for name: String?) -> (() -> Void)? {
        guard let name else { return nil }
        return {
            showAll = false
            CheatsheetStore.shared.query = name
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

/// The program's name at the end of the line, as plain text — and, when there
/// is more to see for it, the button that opens it, brightening under the
/// pointer as the bar's other text controls do. Narrow on purpose: it is a
/// label, and every point it takes is one a hint does not get.
private struct ProgramButton: View {
    let name: String
    let theme: Theme
    let action: (() -> Void)?
    let help: String
    @State private var hovering = false

    var body: some View {
        if let action {
            Button(action: action) {
                label.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .onHover { inside in
                withAnimation(Motion.hover) { hovering = inside }
            }
            .help(help)
            .accessibilityLabel(help)
        } else {
            label
                .help("What is in front of the focused terminal")
                .accessibilityLabel(name)
        }
    }

    private var label: some View {
        HStack(spacing: 3) {
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 96)
            if action != nil {
                Image(systemName: "chevron.up")
                    .font(.system(size: 7, weight: .bold))
            }
        }
        // The status bar's size, a step heavier: it names what the line is for.
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(hovering && action != nil ? theme.textPrimary : theme.textSecondary)
        // Room to hit it, without a shape around it.
        .padding(.vertical, 3)
        .fixedSize()
    }
}

/// One hint: its keys as caps and a word on what they do. A button when a
/// click types something, warming under the pointer like the bar's other
/// controls, and flashing in the accent for a moment when clicked, so a key
/// sent to a program that shows nothing for it was still seen to go.
private struct HintView: View {
    let hint: QuickReferenceHint
    let theme: Theme
    let perform: (() -> Void)?
    @State private var hovering = false
    @State private var flashing = false

    var body: some View {
        if let perform {
            Button {
                flash()
                perform()
            } label: {
                HintLabel(hint: hint, theme: theme, quiet: false)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(background)
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
            // Shown, not typed: its keys drawn quieter, so what a click
            // will do is plain before the pointer gets there.
            HintLabel(hint: hint, theme: theme, quiet: true)
                .padding(.horizontal, 4)
                .help(hint.help)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(hint.label + ": " + hint.caps.joined(separator: " then "))
        }
    }

    private var background: AnyShapeStyle {
        if flashing { return AnyShapeStyle(.tint.opacity(0.3)) }
        return hovering ? AnyShapeStyle(theme.surfaceHover) : AnyShapeStyle(Color.clear)
    }

    private func flash() {
        flashing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            withAnimation(Motion.hover) { flashing = false }
        }
    }
}

/// A hint's keys and its word, as `HintView` draws them and `HintMeasure`
/// measures them: one view, so the width measured is the width drawn.
private struct HintLabel: View {
    let hint: QuickReferenceHint
    let theme: Theme
    let quiet: Bool

    var body: some View {
        // On the text's baseline, so the word sits level with the letters on
        // the caps, not with their middles.
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                ForEach(Array(hint.caps.enumerated()), id: \.offset) { _, cap in
                    KeyCap(symbol: cap, theme: theme, compact: true, tintsModifiers: true, quiet: quiet)
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

/// Every hint laid out as the line would lay it out, never drawn, out of
/// VoiceOver's reach and taking no clicks: only to say how wide each is, for
/// `QuickReferenceFit`. Plain labels, without the buttons, hover and tooltips
/// of the row that is drawn.
private struct HintMeasure: View {
    let content: QuickReferenceContent
    let theme: Theme
    let spacing: CGFloat

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(content.hints) { hint in
                HintLabel(hint: hint, theme: theme, quiet: hint.action == nil)
                    .padding(.horizontal, 4)
                    .fixedSize()
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: HintWidthsKey.self, value: [hint.id: proxy.size.width])
                        }
                    }
            }
            if let note = content.note {
                Text(note)
                    .lineLimit(1)
                    .fixedSize()
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: HintWidthsKey.self,
                                value: [QuickReferenceSessionStrip.noteWidthKey: proxy.size.width]
                            )
                        }
                    }
            }
        }
        .fixedSize()
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct HintWidthsKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct HintRoomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// What each modifier's shade means, for the modifiers the list below has.
private struct ModifierLegend: View {
    let modifiers: [ModifierGlyph]
    let theme: Theme

    var body: some View {
        HStack(spacing: 14) {
            ForEach(modifiers) { modifier in
                HStack(spacing: 4) {
                    Text(String(modifier.rawValue))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(modifier.shade(on: theme))
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

private struct ListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Everything listed for what the strip shows, opened from the program's name
/// at the end of the line or with ⌥⌘/. A click types a key as the strip does,
/// and closes the list so typing goes back to the terminal. Type to narrow it;
/// return types the first key found.
private struct QuickReferenceFullList: View {
    let content: QuickReferenceContent
    let run: (QuickReferenceHint.Action) -> Void
    let openCheatsheet: (() -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID
    @State private var query = ""
    @State private var listHeight: CGFloat = 0
    @FocusState private var searchFocused: Bool

    private struct Group: Identifiable {
        let section: ProgramKeySection
        let entries: [ProgramKeyEntry]
        var id: ProgramKeySection { section }
    }

    /// The sections' keys the search finds, in order.
    private var groups: [Group] {
        content.sections.compactMap { section in
            let entries = ProgramKeyCatalog.filter(content.entries(in: section), matching: query)
            return entries.isEmpty ? nil : Group(section: section, entries: entries)
        }
    }

    /// The command's flags the search finds.
    private var specEntries: [SpecEntry] {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return content.commandEntries }
        return content.commandEntries.filter { entry in
            let words = (entry.display + " " + entry.detail).lowercased()
            return terms.allSatisfy { words.contains($0) }
        }
    }

    /// The modifiers the listed keys use, for the legend: none for a list
    /// without any, and never ⌘, which no program here is sent.
    private var modifiers: [ModifierGlyph] {
        let used = Set(content.sections.flatMap { content.entries(in: $0) }
            .flatMap(\.ways).flatMap { $0 }.flatMap { ModifierGlyph.split($0).modifiers })
        return ModifierGlyph.allCases.filter(used.contains)
    }

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        let groups = groups
        let specEntries = specEntries
        VStack(spacing: 0) {
            searchField(theme: theme)
            if !modifiers.isEmpty {
                ModifierLegend(modifiers: modifiers, theme: theme)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            FadedDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(groups) { group in
                        header(group.section.title, note: note(for: group.section), theme: theme)
                        ForEach(group.entries) { entry in
                            ProgramKeyRow(command: entry, onType: { index in
                                if let text = entry.typed(way: index) { run(.keys(text)) }
                            }, tintsModifiers: true)
                        }
                    }
                    if !specEntries.isEmpty {
                        header(content.badge, note: "From the composer's completion list, for the version macOS ships. Click one to add it to the line.",
                               theme: theme)
                        ForEach(Array(specEntries.enumerated()), id: \.offset) { _, entry in
                            specRow(entry, theme: theme)
                        }
                    }
                    if groups.isEmpty && specEntries.isEmpty {
                        Text("Nothing found for “\(query.trimmingCharacters(in: .whitespaces))”")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                }
                .padding(.bottom, 8)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ListHeightKey.self, value: proxy.size.height)
                    }
                )
            }
            // As tall as what is in it, up to a height that leaves the
            // terminal in view: top's eight keys are not given Vim's room.
            .frame(height: min(max(listHeight, 60), 400))
            .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
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
        .frame(width: 460)
        .background(theme.background)
        .onAppear { searchFocused = true }
    }

    private func searchField(theme: Theme) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
            TextField("Search \(content.badge)'s keys — return types the first", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .onSubmit(runFirst)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.surface)
        )
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    /// Return in the search: the first key found that a click can type, or
    /// the first flag.
    private func runFirst() {
        for group in groups {
            if let entry = group.entries.first(where: \.isClickable), let text = entry.typed(way: entry.stripWay) {
                run(.keys(text))
                return
            }
        }
        if let name = specEntries.first?.names.first { run(.word(name)) }
    }

    /// A section's note, and for a multiplexer with its own prefix set, a word
    /// on the keys below using it.
    private func note(for section: ProgramKeySection) -> String {
        guard let prefix = content.prefixes[section], prefix != section.defaultPrefix else { return section.note }
        return section.note + " This one's prefix is \(prefix), and the keys below use it."
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
