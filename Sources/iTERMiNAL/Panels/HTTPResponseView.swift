import SwiftUI
import AppKit

/// What came back: status, timing, size, collapsible headers, and the body
/// — pretty-printed when it parses as JSON, truncated with a visible marker
/// when it is large. Read-only throughout: `Text`, never `TextEditor`,
/// which would visually invite editing content that was never going
/// anywhere.
struct HTTPResponseView: View {
    @ObservedObject var model: HTTPClientModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @State private var headersExpanded = false
    @State private var copied = false

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        Group {
            if model.isSending {
                sendingView(theme: theme)
            } else if let error = model.lastError {
                errorView(error, theme: theme)
            } else if let response = model.lastResponse, let formatted = model.lastFormatted {
                responseView(response, formatted: formatted, theme: theme)
            } else {
                emptyView(theme: theme)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.background)
    }

    private func sendingView(theme: Theme) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text("Sending…")
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
        }
        .padding(10)
    }

    private func emptyView(theme: Theme) -> some View {
        VStack {
            Spacer()
            Text("Nothing sent yet")
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ error: HTTPClientError, theme: Theme) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(error.errorDescription ?? "The request failed.")
                .font(.system(size: 12))
                .foregroundStyle(theme.textPrimary)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(10)
    }

    private func responseView(
        _ response: HTTPResponseSummary,
        formatted: HTTPResponseFormatter.FormattedBody,
        theme: Theme
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                statusLine(response, theme: theme)

                if !response.headers.isEmpty {
                    DisclosureGroup("Headers (\(response.headers.count))", isExpanded: $headersExpanded) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(response.headers) { header in
                                Text("\(header.name): \(header.value)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(theme.textSecondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                }

                bodyBlock(formatted, theme: theme)
            }
            .padding(10)
        }
    }

    private func statusLine(_ response: HTTPResponseSummary, theme: Theme) -> some View {
        HStack(spacing: 8) {
            Text("\(response.statusCode)")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(response.statusCode < 400 ? Color.green : Color.red)
            Text(String(format: "%.0f ms", response.duration * 1000))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
            Text(ByteCountFormatter.string(fromByteCount: Int64(response.body.count), countStyle: .file))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
            Spacer()
        }
    }

    private func bodyBlock(_ formatted: HTTPResponseFormatter.FormattedBody, theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(formatted.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Button(copied ? "Copied" : "Copy") { copy(formatted.text) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(settings.accentColor.opacity(0.16)))
                Spacer(minLength: 0)
            }
        }
        .padding(8)
        .background(
            // The composer's opaque input-field colour, so a block of fetched
            // text reads as part of the same family as the rest of the app,
            // the same reasoning `CodeBlockView` already uses for AI replies.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(hex: Theme.inputFieldHex(for: colorScheme)))
        )
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}
