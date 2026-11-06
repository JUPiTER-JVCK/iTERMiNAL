import SwiftUI
import AppKit

/// The Cheatsheet page: programs on the left, and for the one chosen its flags
/// and the commands people reach for.
///
/// Typing in the search field narrows the list to the programs that match, best
/// first, as fzf does; the commands that matched are listed first on the page
/// with their matching letters emphasised. Insert takes a command back to the
/// terminal and puts it in the composer's input, no further — it is not run, and
/// any `{{placeholder}}` in it is left for you to fill in.
struct CheatsheetView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var workspace: WorkspaceStore
    @ObservedObject private var cheats = CheatsheetStore.shared
    @Environment(\.colorScheme) private var colorScheme

    @FocusState private var searchFocused: Bool
    @State private var copiedKey: String?
    @State private var showAllExamples = false
    @State private var expandedSubcommands: Set<String> = []

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        VStack(alignment: .leading, spacing: 0) {
            header(theme: theme)
            FadedDivider()
            HStack(spacing: 0) {
                programList(theme: theme)
                    .frame(width: 250)
                FadedDivider(axis: .vertical)
                detail(theme: theme)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            searchFocused = true
            cheats.loadMoreIfNeeded()
        }
        .onChange(of: cheats.selectedProgram) { _, _ in
            showAllExamples = false
            expandedSubcommands = []
        }
    }

    // MARK: Header and search

    private func header(theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Cheatsheet")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Text("Pick a program for its flags and the commands people reach for, or type to narrow the list. Insert takes a command back to the terminal, in the composer's input; you press Return to run it.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            searchField(theme: theme)
            if let status = statusLine {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 16)
    }

    /// What to say about tldr-pages' examples while they are not all there.
    private var statusLine: String? {
        switch cheats.tldr {
        case .notLoaded, .loaded:
            return nil
        case .loading:
            return "Loading more programs…"
        case .missing:
            return "This build does not include the tldr-pages examples, so only the programs written for the app are here."
        case .failed(let message):
            return "The tldr-pages examples could not be loaded: \(message)."
        }
    }

    private func searchField(theme: Theme) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
            TextField("Search programs and commands", text: $cheats.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .autocorrectionDisabled()
                // Return takes the best match, as in fzf; ↑ ↓ move down the list
                // of programs, and Esc clears what is typed.
                .onSubmit {
                    if let example = cheats.bestExampleInSelection { insert(example) }
                }
                .onKeyPress(.upArrow) {
                    cheats.moveSelection(by: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    cheats.moveSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    if cheats.query.isEmpty { return .ignored }
                    cheats.query = ""
                    return .handled
                }
            if !cheats.query.isEmpty {
                Button {
                    cheats.query = ""
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

    // MARK: Programs

    private func programList(theme: Theme) -> some View {
        Group {
            if cheats.rows.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Text("No program matches")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(cheats.rows.enumerated()), id: \.element.id) { position, row in
                                if let heading = listHeading(before: position) {
                                    listHeadingView(heading, theme: theme)
                                }
                                programRow(row, theme: theme)
                                    .id(row.name)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: cheats.selectedProgram) { _, name in
                        if let name { proxy.scrollTo(name) }
                    }
                }
            }
        }
    }

    /// A heading above the row at `position` when the list is the whole library,
    /// split into the programs written for the app and the rest. While searching
    /// the order is the ranking, and nothing interrupts it.
    private func listHeading(before position: Int) -> String? {
        guard !cheats.isSearching else { return nil }
        let rows = cheats.rows
        let row = rows[position]
        let hasOthers = rows.last.map { !$0.isCurated } ?? false
        guard hasOthers else { return nil }
        if position == 0 { return row.isCurated ? "Essentials" : "All programs" }
        if rows[position - 1].isCurated && !row.isCurated { return "All programs" }
        return nil
    }

    private func listHeadingView(_ title: String, theme: Theme) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.textSecondary)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func programRow(_ row: CheatsheetStore.Row, theme: Theme) -> some View {
        let selected = cheats.selectedProgram == row.name
        return Button {
            cheats.selectedProgram = row.name
        } label: {
            HStack(spacing: 8) {
                styled(row.name, matched: row.nameIndices, placeholders: false, base: theme.textPrimary)
                    .font(.system(size: 13, design: .monospaced))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if row.matchCount > 0 {
                    Text("\(row.matchCount)")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? theme.surface : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: A program's page

    @ViewBuilder
    private func detail(theme: Theme) -> some View {
        if let program = cheats.selection {
            ScrollView {
                // Lazy, because a page can have hundreds of examples (git has
                // more than eight hundred) and only the ones on screen need building.
                LazyVStack(alignment: .leading, spacing: 24) {
                    programHeader(program, theme: theme)
                    if let spec = CommandSpecs.spec(named: program.name) {
                        flags(spec, theme: theme)
                    }
                    examples(of: program, theme: theme)
                    footer(for: program, theme: theme)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "text.book.closed")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(theme.textSecondary)
                if cheats.isSearching {
                    Text("Nothing matches “\(cheats.trimmedQuery)”")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                    Text("Try fewer letters, or part of a program's name.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                } else {
                    Text("Choose a program")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func programHeader(_ program: CheatProgram, theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(program.name)
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
            Text(program.summary)
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let address = program.url, let url = URL(string: address) {
                Link("More information", destination: url)
                    .font(.system(size: 12))
            }
            if !program.syntax.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(program.syntax, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(theme.textPrimary)
                            .textSelection(.enabled)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.surface)
                )
            }
        }
    }

    // MARK: Flags

    private func sectionTitle(_ title: String, theme: Theme) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.textSecondary)
            .textCase(.uppercase)
    }

    private func flags(_ spec: CommandSpec, theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(spec.hasSubcommands ? "Flags and subcommands" : "Flags", theme: theme)
            Text("The same table the composer completes from when you press Tab.")
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
            if !spec.options.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(spec.options, id: \.display) { entry in
                        flagRow(entry, theme: theme)
                    }
                }
            }
            if spec.hasSubcommands {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(spec.subcommands, id: \.display) { subcommand in
                        subcommandRow(subcommand, of: spec, theme: theme)
                    }
                }
            }
        }
    }

    private func flagRow(_ entry: SpecEntry, theme: Theme) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(entry.display)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
                .textSelection(.enabled)
                .frame(width: 240, alignment: .leading)
            Text(entry.detail)
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func subcommandRow(_ subcommand: SpecEntry, of spec: CommandSpec, theme: Theme) -> some View {
        let key = subcommand.names[0]
        let options = spec.subcommandOptions[key] ?? []
        if options.isEmpty {
            flagRow(subcommand, theme: theme)
        } else {
            DisclosureGroup(isExpanded: Binding(
                get: { expandedSubcommands.contains(key) },
                set: { setExpanded(key, $0) }
            )) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(options, id: \.display) { entry in
                        flagRow(entry, theme: theme)
                    }
                }
                .padding(.leading, 4)
                .padding(.vertical, 6)
            } label: {
                flagRow(subcommand, theme: theme)
            }
        }
    }

    // MARK: Examples

    /// One line of the examples list. The whole page is a flat list of these, so
    /// that a page with hundreds of examples is built a screenful at a time.
    private struct ExampleItem: Identifiable {
        enum Kind {
            case title(String)
            case heading(String)
            case card(index: Int, hit: CheatHit?)
        }

        let id: String
        let kind: Kind
    }

    private func exampleItems(of program: CheatProgram) -> [ExampleItem] {
        var items: [ExampleItem] = []
        func addAll(title: String) {
            items.append(ExampleItem(id: "title:\(title)", kind: .title(title)))
            for (offset, group) in program.groups().enumerated() {
                if let section = group.section {
                    items.append(ExampleItem(id: "heading:\(offset)", kind: .heading(section)))
                }
                for item in group.items {
                    items.append(ExampleItem(id: "all:\(item.index)", kind: .card(index: item.index, hit: nil)))
                }
            }
        }

        let hits = cheats.hitsInSelection
        if hits.isEmpty {
            addAll(title: "Examples")
        } else {
            items.append(ExampleItem(id: "title:Matches", kind: .title("Matches")))
            for hit in hits {
                items.append(ExampleItem(id: "match:\(hit.example)", kind: .card(index: hit.example, hit: hit)))
            }
            if showAllExamples { addAll(title: "All examples") }
        }
        return items
    }

    @ViewBuilder
    private func examples(of program: CheatProgram, theme: Theme) -> some View {
        let hits = cheats.hitsInSelection
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(exampleItems(of: program)) { item in
                switch item.kind {
                case .title(let title):
                    sectionTitle(title, theme: theme)
                case .heading(let section):
                    Text(section)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .padding(.top, 6)
                case .card(let index, let hit):
                    exampleCard(program.examples[index], key: "\(program.name)#\(index)", hit: hit, theme: theme)
                }
            }
            if !hits.isEmpty && !showAllExamples && program.examples.count > hits.count {
                Button("Show all \(program.examples.count) examples") { showAllExamples = true }
            }
        }
    }

    private func exampleCard(_ example: CheatExample, key: String, hit: CheatHit?, theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                styled(example.description, matched: hit?.descriptionIndices ?? [], placeholders: false, base: theme.textPrimary)
                    .font(.system(size: 13))
                if example.source == .tldr {
                    Text("tldr")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(theme.surfaceBorder)
                        )
                        .help("From tldr-pages, licensed CC BY 4.0")
                }
            }
            HStack(alignment: .top, spacing: 10) {
                styled(example.command, matched: hit?.commandIndices ?? [], placeholders: true, base: theme.textPrimary)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Insert") { insert(example) }
                    .controlSize(.small)
                    .help("Go back to the terminal with this in the composer's input. It is not run.")
                Button(copiedKey == key ? "Copied" : "Copy") { copy(example, key: key) }
                    .controlSize(.small)
                    .help("Copy this to the clipboard")
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.surface)
            )
        }
    }

    // MARK: Footer

    @ViewBuilder
    private func footer(for program: CheatProgram, theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Written by hand for the versions of these tools that macOS ships. Other systems' versions can differ.")
            if program.examples.contains(where: { $0.source == .tldr }) {
                // CC BY 4.0 asks for credit, a link to the licence, and a note that it was changed.
                Text("Examples marked tldr are from [tldr-pages](https://github.com/tldr-pages/tldr), licensed [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). They are reformatted here: options are written out in full, descriptions are tidied, and a subcommand's examples are filed under its program.")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(theme.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Actions

    private func setExpanded(_ subcommand: String, _ open: Bool) {
        if open {
            expandedSubcommands.insert(subcommand)
        } else {
            expandedSubcommands.remove(subcommand)
        }
    }

    private func insert(_ example: CheatExample) {
        workspace.insertIntoComposer(example.command)
    }

    private func copy(_ example: CheatExample, key: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(example.command, forType: .string)
        copiedKey = key
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedKey == key { copiedKey = nil }
        }
    }

    // MARK: Text

    /// `text` with the characters a search matched in the accent colour and
    /// bold, and — in a command — each `{{placeholder}}` in italics, in orange,
    /// so what is yours to fill in stands out.
    private func styled(_ text: String, matched: [Int], placeholders: Bool, base: Color) -> Text {
        CheatCommand.runs(text, matched: matched).reduce(Text("")) { partial, run in
            var piece = Text(run.text)
            if placeholders && run.isPlaceholder {
                piece = piece.italic().foregroundStyle(Color.orange)
            } else {
                piece = piece.foregroundStyle(run.isMatch ? settings.accentColor : base)
            }
            if run.isMatch { piece = piece.bold() }
            return partial + piece
        }
    }
}
