import SwiftUI
import AppKit

/// Settings → General → Profiles: named ways to start a local shell.
///
/// A profile can change the shell, its arguments and environment, and the folder
/// it starts in, and can type one command when you open a tab with it. It does
/// not leave this Mac: it is not in an exported archive.
struct ProfilesSection: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        Section("Profiles") {
            Picker("New tabs open with", selection: $settings.defaultProfileID) {
                Text("The settings above").tag("")
                ForEach(settings.profiles) { profile in
                    Text(profile.displayName).tag(profile.id.uuidString)
                }
            }

            ForEach($settings.profiles) { $profile in
                ProfileEditor(
                    profile: $profile,
                    isDefault: settings.defaultProfileID == profile.id.uuidString,
                    open: { store.openTab(profile: profile) },
                    delete: { delete(profile) }
                )
            }

            Button {
                let name = TerminalProfile.newName(avoiding: settings.profiles.map(\.name))
                settings.profiles.append(TerminalProfile(name: name))
            } label: {
                Label("Add Profile", systemImage: "plus")
            }

            Text("A profile applies to new terminals. Its startup command is typed only when you open a tab yourself — ⌘T, New Tab, the palette or Open a Tab here — never when a workspace is restored, and not in a split. Profiles stay on this Mac and are not part of an exported archive.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func delete(_ profile: TerminalProfile) {
        if settings.defaultProfileID == profile.id.uuidString { settings.defaultProfileID = "" }
        settings.profiles.removeAll { $0.id == profile.id }
    }
}

/// One profile's fields, folded away until asked for.
private struct ProfileEditor: View {
    @Binding var profile: TerminalProfile
    let isDefault: Bool
    let open: () -> Void
    let delete: () -> Void

    var body: some View {
        DisclosureGroup {
            TextField("Name", text: $profile.name)
            TextField("Shell", text: $profile.shellPath, prompt: Text("Same as above, for example /opt/homebrew/bin/fish"))
            TextField("Shell arguments", text: $profile.shellArguments, prompt: Text("For example --no-config"))
            HStack {
                TextField("Start folder", text: $profile.startDirectory, prompt: Text("Same as above"))
                Button("Choose…") { chooseFolder() }
            }

            let problems = profile.variableProblems
            ForEach($profile.variables) { $variable in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        TextField("Variable", text: $variable.name, prompt: Text("NAME"))
                        Text("=").foregroundStyle(.secondary)
                        TextField("Value", text: $variable.value, prompt: Text("value"))
                        Button {
                            profile.variables.removeAll { $0.id == variable.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .help("Remove this variable")
                    }
                    if let problem = problems[variable.id] {
                        Text(problem).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            Button {
                profile.variables.append(ProfileVariable(name: "", value: ""))
            } label: {
                Label("Add Variable", systemImage: "plus")
            }
            .buttonStyle(.link)

            TextField("Startup command", text: $profile.startupCommand, prompt: Text("Typed once the shell is up, for example nvm use"))
            if let problem = profile.startupProblem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("Open a Tab", action: open)
                Spacer()
                Button("Delete Profile", role: .destructive, action: delete)
            }
        } label: {
            HStack {
                Text(profile.displayName)
                if isDefault {
                    Text("default")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.2)))
                }
                Spacer()
                Text(profile.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            profile.startDirectory = url.path
        }
    }
}
