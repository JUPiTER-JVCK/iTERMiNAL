import SwiftUI
import AppKit

/// What the banner's buttons do, so the banner itself stays a view of state.
struct ComposerAIBannerActions {
    /// Put a suggested command in the composer's input. It does not run.
    var insert: (String) -> Void
    /// Explain / Fix it, about the offer being shown or, with nil, about what
    /// the terminal shows now.
    var help: (ErrorHelpKind, ErrorOffer?) -> Void
    /// Send what the consent banner showed.
    var confirm: (ErrorHelpRequest) -> Void
    /// Decline, closing the banner.
    var decline: () -> Void
}

struct ComposerAIBannerView: View {
    let banner: ComposerAIController.Banner
    let theme: Theme
    let actions: ComposerAIBannerActions

    var body: some View {
        switch banner {
        case .notConfigured:
            Text("The AI assistant isn't configured yet — add a provider in Settings → AI.")
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
        case .thinking:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Thinking…")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
            }
        case .reply(let text):
            AssistReplyView(text: text, theme: theme, onInsert: actions.insert)
        case .failure(let message):
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.red.opacity(0.85))
        case .offer(let offer):
            ErrorOfferChip(offer: offer, theme: theme) { kind in
                actions.help(kind, offer)
            }
        case .consent(let request):
            ConsentPrompt(request: request, theme: theme, onSend: { actions.confirm(request) }, onCancel: actions.decline)
        }
    }
}

// MARK: - The offer

/// "That looked like an error · Explain · Fix it".
///
/// Worded as what it is: a guess from the words on screen. It does not say the
/// command failed, because it does not know — a command that merely printed
/// "permission denied" while searching has not.
struct ErrorOfferChip: View {
    let offer: ErrorOffer
    let theme: Theme
    let onChoose: (ErrorHelpKind) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("That looked like an error")
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
            ChipButton(title: "Explain", theme: theme) { onChoose(.explain) }
            ChipButton(title: "Fix it", theme: theme) { onChoose(.fix) }
        }
        .help("Spotted \(offer.reason) in what it printed. Nothing is sent until you press one.")
        .accessibilityElement(children: .contain)
    }
}

private struct ChipButton: View {
    let title: String
    let theme: Theme
    let action: () -> Void

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                // A faint wash of the accent, with the text keeping its own
                // colour so it reads whichever accent was picked.
                .background(Capsule().fill(settings.accentColor.opacity(0.16)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Asking first

/// Shown instead of sending, when "Include recent terminal output" is off:
/// where it would go, what, and a way to see exactly that.
struct ConsentPrompt: View {
    let request: ErrorHelpRequest
    let theme: Theme
    let onSend: () -> Void
    let onCancel: () -> Void

    @State private var showing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(request.consentMessage)
                .font(.system(size: 12))
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                ChipButton(title: "Send", theme: theme, action: onSend)
                ChipButton(title: "Cancel", theme: theme, action: onCancel)
                Button(showing ? "Hide what will be sent" : "Show what will be sent") { showing.toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
            }

            if showing {
                ScrollView {
                    Text(preview)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 140)
            }
        }
    }

    /// Exactly the cleaned text the request holds, which is what is sent.
    private var preview: String {
        var text = ""
        if let command = request.command { text += "Command:\n\(command)\n\n" }
        text += "Output:\n\(request.output)"
        return text
    }
}

// MARK: - The answer

/// A reply with its code blocks set apart: a shell command can be put in the
/// input (never run from here) or copied, anything else can only be copied, and
/// a command that is easy to regret says so first.
struct AssistReplyView: View {
    let text: String
    let theme: Theme
    let onInsert: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(AssistReply.segments(of: text).enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .prose(let prose):
                        Text(prose)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    case .code(let language, let code):
                        CodeBlockView(
                            code: code,
                            isShell: AssistReply.isShell(language: language),
                            theme: theme,
                            onInsert: onInsert
                        )
                    }
                }
            }
        }
        .frame(maxHeight: 240)
    }
}

private struct CodeBlockView: View {
    let code: String
    let isShell: Bool
    let theme: Theme
    let onInsert: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(code)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            if isShell {
                ForEach(CommandRisk.warnings(for: code), id: \.self) { warning in
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text(warning)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textPrimary)
                    }
                }
            }

            HStack(spacing: 8) {
                if isShell {
                    ChipButton(title: "Insert", theme: theme) { onInsert(code) }
                        .help("Put this in the input to review. It doesn't run until you press Return.")
                }
                ChipButton(title: copied ? "Copied" : "Copy", theme: theme) { copy() }
                Spacer(minLength: 0)
            }
        }
        .padding(8)
        .background(
            // The input field's own opaque colour, so this reads as part of the
            // same family and the text on it is on a colour known up front.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(hex: Theme.inputFieldHex(for: colorScheme)))
        )
        .accessibilityElement(children: .contain)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}
