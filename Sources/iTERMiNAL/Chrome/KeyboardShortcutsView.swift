import SwiftUI

/// Every keyboard shortcut in the app, in a window you can search.
///
/// What it lists comes from `ShortcutCatalog` — the same list Settings shows,
/// and the one a test holds to the menus — so there is nothing here to keep in
/// step by hand. Opened from the Help menu (⌘/), the top-right menu, the
/// sidebar's ? button and the command palette.
struct KeyboardShortcutsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        let groups = ShortcutCatalog.groups(matching: query)
        // The programs people run in a terminal, after the app's own keys.
        let editorGroups = ProgramKeyCatalog.groups(matching: query)
        VStack(spacing: 0) {
            header(theme: theme)
            FadedDivider()

            if groups.isEmpty && editorGroups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 22))
                    Text("No shortcut matches “\(query.trimmingCharacters(in: .whitespaces))”")
                        .font(.system(size: 13))
                }
                .foregroundStyle(theme.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list(groups: groups, editorGroups: editorGroups, theme: theme)
            }

            FadedDivider()
            Text("Some actions have no shortcut. The command palette lists every action. The sections after the app's own are for programs you run in a terminal: the app does not handle those keys.")
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Short enough for the window's smallest size, which is 560 high.
        .frame(width: 560, height: 520)
        .background(theme.background)
        .onExitCommand { dismiss() }
        .onAppear { searchFocused = true }
    }

    /// The app's own shortcuts, then the terminal programs'. Its own function —
    /// and its own pieces — because all of it in `body` was more than the
    /// compiler would type-check.
    private func list(groups: [ShortcutGroup], editorGroups: [ProgramKeyGroup], theme: Theme) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groups) { group in
                    shortcutSection(group, theme: theme)
                }
                ForEach(editorGroups) { group in
                    editorSection(group, theme: theme)
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func shortcutSection(_ group: ShortcutGroup, theme: Theme) -> some View {
        Section {
            ForEach(group.entries) { entry in
                ShortcutRow(entry: entry)
            }
        } header: {
            sectionHeader(group.section.title, theme: theme)
        }
    }

    private func editorSection(_ group: ProgramKeyGroup, theme: Theme) -> some View {
        Section {
            ForEach(group.commands) { command in
                ProgramKeyRow(command: command)
            }
        } header: {
            sectionHeader(group.section.title, note: group.section.note, theme: theme)
        }
    }

    private func header(theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Keyboard Shortcuts")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                // Esc, as for any dialog.
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                TextField("Search shortcuts", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.surface)
            )
        }
        .padding(16)
    }

    private func sectionHeader(_ title: String, note: String? = nil, theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            if let note {
                Text(note)
                    .font(.system(size: 11, weight: .regular))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(theme.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
        // Opaque, so rows scrolling under a pinned header do not show
        // through it.
        .background(theme.background)
    }
}

/// One terminal program's command: what it does, and the keys — one run of
/// key caps for each way to do it, with "or" between the ways.
///
/// Shared with the quick reference strip's full list, which passes `onType`:
/// then each way a click can type is a button that types it.
struct ProgramKeyRow: View {
    let command: ProgramKeyEntry
    /// Types the way at an index. Nil, as in the Keyboard Shortcuts window,
    /// leaves the keys as a reference.
    var onType: ((Int) -> Void)?
    /// Colours the modifiers, as the quick reference does throughout.
    var tintsModifiers = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(command.title)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textPrimary)
                if let detail = command.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            if let onType, command.click != .none {
                ways(theme: theme, onType: onType)
            } else {
                ways(theme: theme, onType: nil)
                    // The caps, as one thing, read as the keys in order.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(command.ways.map { $0.joined(separator: " then ") }.joined(separator: " or "))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .accessibilityElement(children: onType == nil ? .combine : .contain)
    }

    private func ways(theme: Theme, onType: ((Int) -> Void)?) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(command.ways.enumerated()), id: \.offset) { index, way in
                if index > 0 {
                    Text("or")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                }
                let caps = HStack(spacing: 3) {
                    ForEach(Array(way.enumerated()), id: \.offset) { _, cap in
                        KeyCap(symbol: cap, theme: theme, tintsModifiers: tintsModifiers)
                    }
                }
                if let onType, command.typed(way: index) != nil {
                    Button { onType(index) } label: { caps.contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .help(QuickReferenceWording.clickHelp(for: command, way: index))
                        .accessibilityLabel("Type " + way.joined(separator: " then "))
                } else {
                    caps
                }
            }
        }
    }
}

/// One shortcut: what it does, and its keys.
private struct ShortcutRow: View {
    let entry: ShortcutEntry
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textPrimary)
                if let detail = entry.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            ShortcutKeys(chords: entry.chords)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// The keys of a shortcut as key caps — ⇧ ⌘ D — with "or" between
/// alternatives. Shared by this window and the Settings page.
struct ShortcutKeys: View {
    let chords: [ShortcutChord]
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        HStack(spacing: 6) {
            ForEach(Array(chords.enumerated()), id: \.offset) { index, chord in
                if index > 0 {
                    Text("or")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                }
                HStack(spacing: 3) {
                    ForEach(Array(chord.symbols.enumerated()), id: \.offset) { _, symbol in
                        KeyCap(symbol: symbol, theme: theme)
                    }
                }
            }
        }
        // One thing to a screen reader, in words — "Shift Command D" — rather
        // than three glyphs it may read out as nothing.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chords.map { $0.words.joined(separator: " ") }.joined(separator: " or "))
    }
}

/// One key, drawn as a cap. `compact` is the quick reference strip's size,
/// which has a single line of the window's bottom to sit in.
struct KeyCap: View {
    let symbol: String
    let theme: Theme
    var compact = false
    /// Draws ⌃ ⌥ ⇧ ⌘ each in a colour of its own, a hair apart from the key,
    /// so which is which reads at a glance in a cap as small as the strip's.
    var tintsModifiers = false

    var body: some View {
        face
            .font(.system(size: compact ? 10 : 11, weight: .medium, design: .monospaced))
            .padding(.horizontal, symbol.count > 1 ? 5 : 0)
            .frame(minWidth: compact ? 18 : 20, minHeight: compact ? 17 : 20)
            // A key shown cut down reads as "…", which says nothing: a cap is
            // always as wide as what is on it.
            .fixedSize()
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(theme.surfaceBorder)
            )
    }

    @ViewBuilder
    private var face: some View {
        let parts = ModifierGlyph.split(symbol)
        if tintsModifiers, !parts.modifiers.isEmpty {
            HStack(spacing: 1.5) {
                ForEach(Array(parts.modifiers.enumerated()), id: \.offset) { _, modifier in
                    Text(String(modifier.rawValue))
                        .fontWeight(.semibold)
                        .foregroundStyle(modifier.tint)
                }
                if !parts.key.isEmpty {
                    Text(parts.key)
                        .foregroundStyle(theme.textPrimary)
                }
            }
        } else {
            Text(symbol)
                .foregroundStyle(theme.textPrimary)
        }
    }
}

/// The modifier keys as caps print them, each with the colour the quick
/// reference gives it. System colours, so each keeps its contrast in light and
/// dark and under Increase Contrast.
enum ModifierGlyph: Character, CaseIterable, Identifiable {
    case control = "⌃"
    case option = "⌥"
    case shift = "⇧"
    case command = "⌘"

    var id: Character { rawValue }

    var name: String {
        switch self {
        case .control: return "Control"
        case .option: return "Option"
        case .shift: return "Shift"
        case .command: return "Command"
        }
    }

    var tint: Color {
        switch self {
        case .control: return Color(nsColor: .systemOrange)
        case .option: return Color(nsColor: .systemPurple)
        case .shift: return Color(nsColor: .systemGreen)
        case .command: return Color(nsColor: .systemBlue)
        }
    }

    /// The modifiers a cap starts with, and the key after them: "⌃X" is
    /// Control and "X". A cap with none has them empty.
    static func split(_ cap: String) -> (modifiers: [ModifierGlyph], key: String) {
        var modifiers: [ModifierGlyph] = []
        var rest = Substring(cap)
        while let first = rest.first, let modifier = ModifierGlyph(rawValue: first) {
            modifiers.append(modifier)
            rest = rest.dropFirst()
        }
        return (modifiers, String(rest))
    }
}
