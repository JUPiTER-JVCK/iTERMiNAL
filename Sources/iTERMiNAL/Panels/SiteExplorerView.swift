import SwiftUI

/// The explorer's screen: a transcript, and a prompt under it. Type `help`.
///
/// Deliberately plain — monospaced text in a scroll view and one text field —
/// because the point is the command line, and because every extra control
/// would be one more thing to get wrong without a Mac to look at it on.
struct SiteExplorerView: View {
    @ObservedObject var explorer: SiteExplorerModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var promptFocused: Bool

    private static let bottomID = "explorer-bottom"

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(explorer.lines) { line in
                            Text(line.text)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(color(for: line.kind, theme: theme))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(line.id)
                        }
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .onChange(of: explorer.lines.last?.id) { _, _ in
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }

            FadedDivider()
            promptRow(theme: theme)
        }
        .background(theme.background)
        .onAppear {
            explorer.showGreetingIfNeeded()
            promptFocused = true
        }
    }

    private func promptRow(theme: Theme) -> some View {
        HStack(spacing: 8) {
            Text(explorer.prompt)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(settings.accentColor)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: 240, alignment: .leading)
                .layoutPriority(1)

            TextField("", text: $explorer.input)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
                .autocorrectionDisabled()
                .focused($promptFocused)
                .onSubmit { explorer.submit(settings: settings) }
                // Shell habits: ↑ ↓ recall earlier lines, Tab completes a
                // name from what is on the map, Esc cancels what is running
                // or clears what is typed.
                .onKeyPress(.upArrow) {
                    explorer.recallPrevious()
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    explorer.recallNext()
                    return .handled
                }
                .onKeyPress(.tab) {
                    explorer.complete()
                    return .handled
                }
                .onKeyPress(.escape) {
                    if explorer.isWorking {
                        explorer.cancel()
                        return .handled
                    }
                    if !explorer.input.isEmpty {
                        explorer.input = ""
                        return .handled
                    }
                    return .ignored
                }

            if explorer.isWorking {
                ProgressView()
                    .controlSize(.small)
                Button("Cancel") { explorer.cancel() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func color(for kind: SiteExplorerModel.LineKind, theme: Theme) -> Color {
        switch kind {
        case .input: return theme.textPrimary.opacity(0.65)
        case .output: return theme.textPrimary
        case .note: return theme.textSecondary
        case .error: return .red
        }
    }
}
