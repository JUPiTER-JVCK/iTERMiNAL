import SwiftUI
import AppKit

/// "Test File Access" for a saved host: signs in the way the file browser does
/// and reports what happened, in the same words the browser would use.
///
/// Finding out here, with the host's settings in front of you, beats finding
/// out by opening the Files panel and being shown an error.
struct ConnectionTestRow: View {
    let connection: SSHConnection

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @State private var isTesting = false
    @State private var result: Outcome?
    /// What a sign-in tab that could not be shared has to say.
    @State private var signInNote: String?

    private enum Outcome {
        case signedIn(path: String, count: Int, shared: Bool)
        case problem(RemoteProblem)
        case other(String)
    }

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(isTesting ? "Testing…" : "Test File Access") { runTest() }
                    .disabled(isTesting || connection.host.trimmingCharacters(in: .whitespaces).isEmpty)
                if isTesting {
                    ProgressView().controlSize(.small)
                }
            }

            switch result {
            case .signedIn(let path, let count, let shared)?:
                Label(
                    "Signed in\(shared ? ", through a terminal tab" : ""). \(count) item\(count == 1 ? "" : "s") in \(path).",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(.green)
            case .problem(let problem)?:
                RemoteProblemView(problem: problem, theme: theme, perform: perform)
                    .frame(height: 300)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.surface)
                    )
            case .other(let message)?:
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            case nil:
                Text("Signs in the way the Files panel does: with a key, or through a terminal tab you have signed in to, since a file browser has nowhere to type a password.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let signInNote {
                Label(signInNote, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        // A different host is a different test.
        .id(connection.id)
    }

    private func runTest() {
        isTesting = true
        result = nil
        signInNote = nil
        let provider = SFTPFileSystemProvider(connection: connection)
        provider.list(provider.defaultPath(), showHidden: false) { outcome in
            isTesting = false
            switch outcome {
            case .success(let listing):
                result = .signedIn(path: listing.path, count: listing.items.count, shared: provider.usesSharedSignIn)
            case .failure(let error):
                if case FileProviderError.remote(let problem) = error {
                    result = .problem(problem)
                } else {
                    result = .other(error.localizedDescription)
                }
            }
        }
    }

    /// Buttons that open a terminal do it in the main window, which this page
    /// is not — so the main window is brought forward to show it.
    private func perform(_ action: RemoteAction) {
        switch action {
        case .tryAgain:
            runTest()
        case .signInInTerminal:
            signInNote = WorkspaceStore.shared.newSharedSignIn(for: connection)
            openWindow(id: "main")
        case .runInLocalTerminal(_, let command):
            WorkspaceStore.shared.newTab(typing: command)
            openWindow(id: "main")
        case .editConnection:
            // Already on the page that edits it.
            break
        }
    }
}
