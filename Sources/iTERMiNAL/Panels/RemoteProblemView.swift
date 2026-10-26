import SwiftUI
import AppKit

/// What a remote host's failure says, laid out so it can be acted on: the
/// problem in a line, why, the steps in order, the buttons, and — folded away
/// but never replaced — the exact words `sftp` used.
///
/// Shown in place of the folder listing when a host could not be read, and in
/// a popover from the strip when a transfer or a change failed.
struct RemoteProblemView: View {
    let problem: RemoteProblem
    let theme: Theme
    let perform: (RemoteAction) -> Void

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @State private var outputExpanded = false
    @State private var copiedCommand: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(problem.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .textSelection(.enabled)
                }

                Text(problem.explanation)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if !problem.steps.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("What you can do")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                        ForEach(Array(problem.steps.enumerated()), id: \.offset) { index, step in
                            stepRow(number: index + 1, step: step)
                        }
                    }
                }

                actionRow

                if !problem.output.isEmpty {
                    DisclosureGroup("What sftp said", isExpanded: $outputExpanded) {
                        Text(problem.output)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(.top, 4)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                }
            }
            .padding(14)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func stepRow(number: Int, step: RemoteStep) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 18, alignment: .trailing)
            VStack(alignment: .leading, spacing: 5) {
                Text(step.text)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let command = step.command {
                    commandBox(command)
                }
            }
        }
    }

    /// A command, apart from the sentence, with a button that copies it. It is
    /// only ever copied, or typed at a prompt — never run from here.
    private func commandBox(_ command: String) -> some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copiedCommand == command ? "Copied" : "Copy") { copy(command) }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textPrimary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(hex: Theme.inputFieldHex(for: colorScheme)))
        )
    }

    private var actionRow: some View {
        // Wraps rather than truncating: four buttons do not fit a narrow panel
        // on one line.
        FlowLayout(spacing: 6) {
            ForEach(Array(problem.actions.enumerated()), id: \.offset) { _, action in
                Button(action.title) { perform(action) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(settings.accentColor.opacity(action == .tryAgain ? 0.26 : 0.14)))
            }
        }
    }

    private func copy(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copiedCommand = command
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedCommand == command { copiedCommand = nil }
        }
    }
}
