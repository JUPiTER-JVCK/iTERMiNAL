import SwiftUI
import AppKit

/// The local scripting API's controls, plus a plain statement of what the app
/// does and doesn't do with the user's data.
struct SecuritySettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var installMessage: String?
    @State private var tokenMessage: String?

    var body: some View {
        Form {
            Section("Local scripting API") {
                Toggle("Enable local API", isOn: $settings.localAPIEnabled)
                Text("Lets scripts, the iterminalctl command, and AI agents drive this app over a Unix socket. It can type into live shells, so it stays off until you turn it on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.localAPIEnabled {
                    Toggle("Allow sending input to terminals", isOn: $settings.apiAllowTerminalInput)
                    Toggle("Allow controlling the browser pane", isOn: $settings.apiAllowBrowserControl)

                    LabeledContent("Socket") {
                        Text(LocalAPIServer.shared.socketPath)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }

                    HStack {
                        Button("Copy Token") {
                            // A nil token means the keychain refused or the
                            // RNG failed; say so rather than copying nothing.
                            guard let token = LocalAPIServer.shared.ensureToken() else {
                                tokenMessage = "Couldn't read or create a token in your keychain."
                                return
                            }
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(token, forType: .string)
                            tokenMessage = "Token copied to the clipboard."
                        }
                        Button("Regenerate Token") {
                            tokenMessage = LocalAPIServer.shared.regenerateToken() == nil
                                ? "Couldn't create a new token in your keychain."
                                : "New token created. The old one no longer works."
                        }
                    }

                    if let tokenMessage {
                        Text(tokenMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if settings.localAPIEnabled {
                Section("Command line tool") {
                    Button("Install iterminalctl…") { installCLI() }
                    if let installMessage {
                        Text(installMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Copies the bundled iterminalctl into ~/.local/bin.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("How your data is handled") {
                Text("""
                • The API socket is created with owner-only permissions inside a private folder, and every request must present a token kept in your keychain.
                • Secrets live only in the keychain — never in preferences, the saved layout, or exported snapshots.
                • SSH authentication is delegated to the system; this app cannot prompt for or store a password.
                • App Transport Security stays enabled; only the embedded web view may load plain HTTP, so you can preview a local dev server.
                • A terminal can't run inside the macOS sandbox — it exists to launch your programs — so capabilities are narrowed individually instead.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func installCLI() {
        guard let source = Bundle.main.url(forResource: "iterminalctl", withExtension: nil) else {
            installMessage = "The bundled tool wasn't found in the app bundle."
            return
        }
        let destinationDirectory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local/bin", isDirectory: true)
        let destination = destinationDirectory.appendingPathComponent("iterminalctl")
        do {
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            installMessage = "Installed to \(destination.path). Add ~/.local/bin to your PATH if it isn't already."
        } catch {
            installMessage = "Install failed: \(error.localizedDescription)"
        }
    }
}
