import SwiftUI
import AppKit

/// Settings → Terminal → Colored output: the switches, and a sample of what
/// they do drawn in the current theme.
struct OutputColorsSettingsSection: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @State private var copied = false

    /// Typed by hand because a command only colors when asked: `grep` prints
    /// its matches plain unless it is given `--color`, whatever the
    /// environment says. This app does not edit shell startup files.
    private static let grepAliases = """
    alias grep='grep --color=auto'
    alias egrep='egrep --color=auto'
    alias fgrep='fgrep --color=auto'
    """

    var body: some View {
        Section("Colored output") {
            Toggle("Color command output", isOn: $settings.colorizeOutput)
            Toggle("ls: directories, links and scripts", isOn: $settings.colorizeListings)
                .disabled(!settings.colorizeOutput)
            Toggle("man pages and less", isOn: $settings.colorizeManPages)
                .disabled(!settings.colorizeOutput)

            OutputColorsPreview(
                theme: settings.resolvedTerminalTheme(darkMode: colorScheme == .dark),
                listings: settings.colorizeOutput && settings.colorizeListings,
                manPages: settings.colorizeOutput && settings.colorizeManPages
            )

            Text("""
            Applies to new terminals. The colors are your theme's own — bold blue is whatever blue the theme calls blue — so they follow a theme change. \
            Your shell's startup files run afterwards, so anything you set there wins, and the NO_COLOR convention switches this off.
            """)
                .font(.caption)
                .foregroundStyle(.secondary)

            DisclosureGroup("grep, GNU ls and other commands") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Some commands print color only when asked. For grep, add these to your .zshrc — iTERMiNAL doesn't edit your shell's files:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .top) {
                        Text(Self.grepAliases)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button(copied ? "Copied" : "Copy") { copy() }
                    }
                    Text("macOS's own ls colors folders, links and programs, and nothing else. GNU ls (with --color) and eza also read LS_COLORS, which is set too, and color archives, pictures and audio.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.grepAliases + "\n", forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

/// A few lines of `ls -l` and a man page in the theme's own colors.
///
/// Drawn from the same tables the environment is written from, so the sample
/// cannot say one thing while the terminal does another. The listing is what
/// macOS's own `ls` prints, which colors by kind of file and never by ending:
/// a picture or an archive is plain there, and only the tools that read
/// `LS_COLORS` color it.
private struct OutputColorsPreview: View {
    let theme: TerminalTheme
    let listings: Bool
    let manPages: Bool

    private var palette: [UInt32] { theme.ansi }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(listingRows.enumerated()), id: \.offset) { _, row in
                line(row)
            }
            Spacer().frame(height: 8)
            ForEach(Array(manRows.enumerated()), id: \.offset) { _, row in
                line(row)
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(hex: theme.background)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A sample of colored ls and man page output in this theme")
    }

    // MARK: Rows

    private typealias Run = (text: String, sgr: String?)

    private func run(_ text: String, _ sgr: String? = nil) -> Run {
        (text: text, sgr: sgr)
    }

    private func style(_ kind: OutputColors.ListingKind) -> String? {
        listings ? OutputColors.listingStyles.first { $0.kind == kind }?.sgr : nil
    }

    private var listingRows: [[Run]] {
        var rows: [[Run]] = []
        rows.append([run("drwxr-xr-x  "), run("Documents", style(.directory))])
        rows.append([run("lrwxr-xr-x  "), run("current", style(.symlink)), run(" -> releases/v2.4")])
        rows.append([run("-rwxr-xr-x  "), run("deploy.sh", style(.executable))])
        rows.append([run("-rw-r--r--  "), run("notes.txt")])
        rows.append([run("-rw-r--r--  "), run("photo.png")])
        return rows
    }

    private func man(_ variable: String) -> String? {
        manPages ? OutputColors.manPageStyles.first { $0.variable == variable }?.sgr : nil
    }

    private var manRows: [[Run]] {
        let bold = man("LESS_TERMCAP_md")
        let underline = man("LESS_TERMCAP_us")
        let status = man("LESS_TERMCAP_so")
        var rows: [[Run]] = []
        rows.append([run("NAME", bold)])
        rows.append([run("     ls", bold), run(" – list directory contents")])
        rows.append([run("SYNOPSIS", bold)])
        rows.append([run("     ls", bold), run(" ["), run("-lAh", bold), run("] ["), run("file", underline), run(" ...]")])
        rows.append([run(" Manual page ls(1) line 1 (press h for help or q to quit) ", status)])
        return rows
    }

    private func line(_ runs: [Run]) -> some View {
        runs.reduce(Text("")) { partial, piece in partial + text(piece) }
            .lineLimit(1)
    }

    /// One run, drawn as a terminal would draw its SGR codes: the color from
    /// the theme's sixteen, and — as SwiftTerm does — the bright one for bold.
    private func text(_ piece: Run) -> Text {
        var foregroundIndex: Int?
        var bold = false
        var underline = false
        var backgroundIndex: Int?
        for code in (piece.sgr ?? "").split(separator: ";").compactMap({ Int($0) }) {
            switch code {
            case 0: foregroundIndex = nil; bold = false; underline = false; backgroundIndex = nil
            case 1: bold = true
            case 4: underline = true
            case 30...37: foregroundIndex = code - 30
            case 40...47: backgroundIndex = code - 40
            default: break
            }
        }
        // SwiftTerm draws bold text in the bright variant of the first seven.
        if bold, let index = foregroundIndex, index < 7 { foregroundIndex = index + 8 }
        let foreground = Color(hex: foregroundIndex.map { palette[$0] } ?? theme.foreground)

        if let backgroundIndex {
            // `Text` has no background; an attributed string does.
            var attributed = AttributedString(piece.text)
            attributed.foregroundColor = foreground
            attributed.backgroundColor = Color(hex: palette[backgroundIndex])
            if bold { attributed.inlinePresentationIntent = .stronglyEmphasized }
            return Text(attributed)
        }
        var result = Text(piece.text).foregroundColor(foreground)
        if bold { result = result.bold() }
        if underline { result = result.underline() }
        return result
    }
}
