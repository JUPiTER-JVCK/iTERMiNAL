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
                    // Like a terminal: a click anywhere in the transcript puts
                    // you back at the prompt. A drag still selects text.
                    .contentShape(Rectangle())
                    .onTapGesture { promptFocused = true }
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
        // Focus asked for in the same pass that puts the field in the window is
        // sometimes dropped — and while it is, typed text goes to whatever had
        // focus before (the terminal beside this panel), not to the prompt.
        .task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            promptFocused = true
        }
        // A finished command, or a click on Cancel, leaves focus elsewhere.
        .onChange(of: explorer.isWorking) { _, working in
            if !working { promptFocused = true }
        }
    }

    private func promptRow(theme: Theme) -> some View {
        HStack(spacing: 8) {
            // Its natural width: `ExplorerFormat.prompt` keeps it short. A
            // `.frame(maxWidth:)` here would grow to that width whatever the
            // text, and push the field away from the prompt it belongs to.
            Text(explorer.prompt)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(settings.accentColor)
                .lineLimit(1)
                .fixedSize()

            // With a placeholder, so there is something to see where to type.
            TextField("", text: $explorer.input, prompt: Text("type an address (example.com), or help"))
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
            } else {
                // Return runs the line; this is the same thing for a click.
                Button { explorer.submit(settings: settings) } label: {
                    Image(systemName: "return")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(explorer.input.isEmpty ? theme.textSecondary.opacity(0.5) : theme.textPrimary)
                }
                .buttonStyle(.plain)
                .disabled(explorer.input.isEmpty)
                .help("Run (Return)")
                .accessibilityLabel("Run")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // A visible field, so it is clear where the typing goes.
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.surface)
        )
        .contentShape(Rectangle())
        .onTapGesture { promptFocused = true }
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
