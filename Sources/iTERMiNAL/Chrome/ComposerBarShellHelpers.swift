import SwiftUI
import AppKit

/// Carries the composer card's rendered size up to the view that clamps its
/// drag, so the clamp knows how much card it is keeping on screen.
struct ComposerSizeKey: PreferenceKey {
    static let defaultValue = CGSize.zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// Chooses which shell the composer's own session runs.
///
/// Scoped to the composer on purpose: this is where you try a one-off command,
/// and wanting it in bash shouldn't change what every new tab opens as. Only
/// shells that exist on this Mac are offered — listing one that isn't
/// installed would just produce a session that fails to launch.
struct ComposerShellPicker: View {
    let theme: Theme

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: WorkspaceStore


    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text("Shell")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                Text("Applies to the composer only")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textSecondary)
            }

            Spacer(minLength: 8)

            // A real label, hidden visually: the "Shell" text beside this is
            // decoration as far as assistive technology is concerned, so an
            // empty label would leave the control unnamed.
            Picker("Shell", selection: shellBinding) {
                Text("Default").tag("")
                ForEach(ComposerShells.available, id: \.path) { shell in
                    Text(shell.name).tag(shell.path)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Changing the shell restarts the composer's session — the running one
    /// is still the old shell, and leaving it would make the picker a lie.
    private var shellBinding: Binding<String> {
        Binding(
            get: { settings.composerShell },
            set: { newValue in
                guard newValue != settings.composerShell else { return }
                settings.composerShell = newValue
                store.resetComposerSession()
            }
        )
    }
}

/// The shells the composer offers, resolved once.
///
/// Shared by the composer's own popover and the Composer settings pane so the
/// two can never disagree about what is installed.
enum ComposerShells {
    /// Checked once: the set of installed shells does not change while the
    /// app is running.
    ///
    /// Resolved through the user's own PATH rather than a list of guessed
    /// locations. Hardcoding the two Homebrew prefixes missed MacPorts, Nix,
    /// and anything else on PATH, so a shell could be installed and still not
    /// be offered.
    static let available: [(path: String, name: String)] = {
        let names = ["zsh", "bash", "sh", "fish"]
        let searchPath = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        // /bin last so a user's preferred build shadows the system copy, and
        // present even when PATH is empty (a GUI app can inherit very little).
        let directories = searchPath + ["/bin", "/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"]

        var seen = Set<String>()
        var found: [(path: String, name: String)] = []
        for name in names {
            for directory in directories {
                let path = (directory as NSString).appendingPathComponent(name)
                guard FileManager.default.isExecutableFile(atPath: path) else { continue }
                // Resolve symlinks so /usr/local/bin/fish and its real target
                // are not offered as two separate choices.
                let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                guard seen.insert(resolved).inserted else { continue }
                found.append((path, name))
                break
            }
        }
        return found
    }()
}
