import SwiftUI

/// Every keyboard shortcut in the app, in a window you can search.
///
/// What it lists comes from `ShortcutCatalog` — the same list Settings shows,
/// and the one a test holds to the menus — so there is nothing here to keep in
/// step by hand. Opened from the Help menu (⌘/), the top-right menu, the
/// sidebar's ? button and the command palette.
struct KeyboardShortcutsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        let groups = ShortcutCatalog.groups(matching: query)
        VStack(spacing: 0) {
            header(theme: theme)
            FadedDivider()

            if groups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 22))
                    Text("No shortcut matches “\(query.trimmingCharacters(in: .whitespaces))”")
                        .font(.system(size: 13))
                }
                .foregroundStyle(theme.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups) { group in
                            Section {
                                ForEach(group.entries) { entry in
                                    ShortcutRow(entry: entry)
                                }
                            } header: {
                                sectionHeader(group.section.title, theme: theme)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }

            FadedDivider()
            Text("Some actions have no shortcut. The command palette lists every action.")
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

    private func sectionHeader(_ title: String, theme: Theme) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
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

/// One shortcut: what it does, and its keys.
private struct ShortcutRow: View {
    let entry: ShortcutEntry
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
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

    var body: some View {
        let theme = Theme.current(for: colorScheme)
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

private struct KeyCap: View {
    let symbol: String
    let theme: Theme

    var body: some View {
        Text(symbol)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, symbol.count > 1 ? 5 : 0)
            .frame(minWidth: 20, minHeight: 20)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(theme.surfaceBorder)
            )
    }
}
