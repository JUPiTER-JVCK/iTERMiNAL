import SwiftUI
import AppKit

/// What Settings → Connections → SSH keys shows: the public keys in `~/.ssh`,
/// each one's fingerprint, and whether the ssh-agent this app was started with
/// holds it. The rules about what is read and what is only typed are
/// `SSHKeys`'s.
///
/// Not `@MainActor`, like the other models here: the work is done off the main
/// thread and what it found is published on it.
final class SSHKeysModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let entry: SSHKeys.Entry
        /// Nil when `ssh-keygen` could not read the file as a public key.
        let fingerprint: SSHKeys.Fingerprint?
        /// The line to copy, when the file reads as a key.
        let publicKey: String?
        /// Nil when the agent could not be asked.
        let inAgent: Bool?

        var id: String { entry.name }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var omitted = 0
    /// Nil until the agent has been asked.
    @Published private(set) var agent: SSHKeys.AgentState?
    /// Every file name in `~/.ssh`, so a new key cannot be given a taken one.
    @Published private(set) var fileNames: Set<String> = []
    @Published private(set) var loading = false
    @Published private(set) var loaded = false

    func refresh() {
        guard !loading else { return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let snapshot = Self.read()
            DispatchQueue.main.async {
                guard let self else { return }
                self.rows = snapshot.rows
                self.omitted = snapshot.omitted
                self.agent = snapshot.agent
                self.fileNames = snapshot.fileNames
                self.loading = false
                self.loaded = true
            }
        }
    }

    private struct Snapshot {
        var rows: [Row]
        var omitted: Int
        var agent: SSHKeys.AgentState
        var fileNames: Set<String>
    }

    /// Everything that touches the disk or starts a program, in one place and
    /// off the main thread. Private keys are only `stat`ed.
    private static func read() -> Snapshot {
        let directory = NSHomeDirectory() + "/.ssh"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        let listing = SSHKeys.listing(fileNames: names) { name in
            var info = stat()
            guard stat(directory + "/" + name, &info) == 0 else { return .missing }
            return SSHKeys.privateKey(isFile: (info.st_mode & S_IFMT) == S_IFREG, mode: Int(info.st_mode))
        }
        let agent = agentState()
        var rows: [Row] = []
        for entry in listing.entries {
            let path = directory + "/" + entry.publicFile
            // A pipe or a device where a file should be is neither read nor
            // handed to ssh-keygen, which would wait on it.
            let plain = isRegularFile(path)
            let printed = plain ? fingerprint(ofFile: path) : nil
            rows.append(Row(
                entry: entry,
                fingerprint: printed,
                publicKey: plain ? publicKeyLine(inFile: path) : nil,
                inAgent: printed.flatMap { SSHKeys.isLoaded($0, in: agent) }
            ))
        }
        return Snapshot(rows: rows, omitted: listing.omitted, agent: agent, fileNames: Set(names))
    }

    /// A plain file (or a link to one), not a pipe, a device or a folder.
    private static func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    /// What `ssh-keygen -l` says of a public key file. Its own reading is the
    /// authority on whether the file is a key; a file it cannot read, or does
    /// not read within a few seconds, has none.
    private static func fingerprint(ofFile path: String) -> SSHKeys.Fingerprint? {
        guard let result = ProcessRunner.run("/usr/bin/ssh-keygen", ["-l", "-f", path], timeout: 5),
              result.status == 0, !result.timedOut,
              let first = result.output.split(whereSeparator: \.isNewline).first else { return nil }
        return SSHKeys.parseFingerprint(String(first))
    }

    /// The key line in a `.pub` file, read only if it is of the size a key
    /// has, and never more than that.
    private static func publicKeyLine(inFile path: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0, info.st_size <= off_t(SSHKeys.maxPublicFileBytes),
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: SSHKeys.maxPublicFileBytes) else { return nil }
        return SSHKeys.publicKeyLine(from: String(decoding: data, as: UTF8.self))
    }

    /// `ssh-add -l`: it lists, and never asks for anything.
    private static func agentState() -> SSHKeys.AgentState {
        guard let result = ProcessRunner.run("/usr/bin/ssh-add", ["-l"], timeout: 5), !result.timedOut else {
            return .failed
        }
        return SSHKeys.agentState(status: result.status, output: result.output, errorOutput: result.errorOutput)
    }
}

/// Settings → Connections → SSH keys.
struct SSHKeysSection: View {
    @StateObject private var model = SSHKeysModel()
    @Environment(\.openWindow) private var openWindow
    @State private var generating = false
    @State private var notice: String?

    var body: some View {
        Section("SSH keys") {
            Text(agentLine)
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.rows.isEmpty {
                Text(model.loaded ? "There are no public keys (.pub files) in ~/.ssh." : "Looking in ~/.ssh…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.rows) { row in
                    SSHKeyRow(row: row, onType: typeIntoTab, onCopy: copy)
                }
                if model.omitted > 0 {
                    Text("\(model.omitted) more are not listed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Generate New Key…") { generating = true }
                Button("Refresh") { model.refresh() }
                    .disabled(model.loading)
            }

            Text("Lists the public keys in ~/.ssh and asks the ssh-agent this app was started with what it holds. Private keys are never opened, and nothing here asks for a passphrase: Add to Agent and Generate type the ssh-add or ssh-keygen command into a new tab and leave Return to you, so ssh itself asks.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { model.refresh() }
        .sheet(isPresented: $generating) {
            GenerateSSHKeySheet(existing: model.fileNames, onType: typeIntoTab)
        }
    }

    private var agentLine: String {
        switch model.agent {
        case nil:
            return "Asking the ssh-agent…"
        case .keys(let held)?:
            return "The ssh-agent this app was started with holds \(held.count) key\(held.count == 1 ? "" : "s")."
        case .empty?:
            return "The ssh-agent this app was started with is running and holds no keys."
        case .unreachable?:
            return "No ssh-agent answered, so whether a key is loaded can't be shown."
        case .failed?:
            return "The ssh-agent could not be read, so whether a key is loaded can't be shown."
        }
    }

    /// A command is typed into a new tab and left for you to run.
    private func typeIntoTab(_ command: String) {
        WorkspaceStore.shared.newTab(typing: command)
        openWindow(id: "main")
    }

    private func copy(_ text: String, what: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notice = "Copied \(what)."
    }
}

private struct SSHKeyRow: View {
    let row: SSHKeysModel.Row
    let onType: (String) -> Void
    let onCopy: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .foregroundStyle(.secondary)
                Text(row.entry.name)
                    .font(.system(.body, design: .monospaced))
                if let fingerprint = row.fingerprint {
                    Text("\(fingerprint.type) · \(fingerprint.bits)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                agentBadge
                actions
            }
            if let fingerprint = row.fingerprint {
                Text(fingerprint.hash)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if !fingerprint.comment.isEmpty {
                    Text(fingerprint.comment)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("ssh-keygen could not read \(row.entry.publicFile) as a public key.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            privateKeyNote
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var agentBadge: some View {
        switch row.inAgent {
        case true?:
            Label("In agent", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        case false?:
            Text("Not in agent")
                .font(.caption)
                .foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var privateKeyNote: some View {
        switch row.entry.privateKey {
        case .ok:
            EmptyView()
        case .missing:
            Text("There is no private key file named \(row.entry.name) beside it. That is fine for a key that lives in a hardware token or another agent.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .tooOpen(let mode):
            Label("The private key's permissions (\(String(mode, radix: 8))) are too open, so ssh refuses to use it.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var actions: some View {
        Menu {
            Button("Copy Public Key") {
                if let key = row.publicKey { onCopy(key, "the public key") }
            }
            .disabled(row.publicKey == nil)
            Button("Copy Fingerprint") {
                if let fingerprint = row.fingerprint { onCopy(fingerprint.hash, "the fingerprint") }
            }
            .disabled(row.fingerprint == nil)
            Button("Reveal in Finder") {
                let file = NSHomeDirectory() + "/.ssh/" + row.entry.publicFile
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)])
            }
            Divider()
            Button("Add to Agent…") {
                onType(SSHKeys.addToAgentCommand(keyName: row.entry.name))
            }
            .disabled(row.entry.privateKey == .missing || row.inAgent == true)
            if case .tooOpen = row.entry.privateKey {
                Button("Make Private Key Private…") {
                    onType(SSHKeys.fixPermissionsCommand(keyName: row.entry.name))
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// The sheet for making a key. It builds one `ssh-keygen` line and types it
/// into a tab; the passphrase is asked there, by ssh-keygen.
private struct GenerateSSHKeySheet: View {
    let existing: Set<String>
    let onType: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind = SSHKeys.KeyKind.ed25519
    @State private var name: String
    @State private var comment: String

    init(existing: Set<String>, onType: @escaping (String) -> Void) {
        self.existing = existing
        self.onType = onType
        _name = State(initialValue: SSHKeys.suggestedName(for: .ed25519, existing: existing))
        _comment = State(initialValue: SSHKeys.defaultComment(user: NSUserName(), computerName: Host.current().localizedName))
    }

    private var result: Result<String, SSHKeys.GenerateProblem> {
        SSHKeys.generateCommand(kind: kind, name: name, comment: comment, existing: existing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Generate a New SSH Key")
                .font(.headline)

            Picker("Type", selection: $kind) {
                ForEach(SSHKeys.KeyKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            TextField("File name in ~/.ssh", text: $name)
            TextField("Comment", text: $comment)

            switch result {
            case .success(let command):
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            case .failure(let problem):
                Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text("This opens a terminal tab with the command typed in and waits for you to press Return. ssh-keygen then asks for a passphrase there: iTERMiNAL never sees it, and a name that is taken is not offered.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Type in New Tab") {
                    if case .success(let command) = result {
                        onType(command)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onChange(of: kind) { old, new in
            // A name still on offer follows the type; one that was typed stays.
            if name == SSHKeys.suggestedName(for: old, existing: existing) {
                name = SSHKeys.suggestedName(for: new, existing: existing)
            }
        }
    }

    private var isValid: Bool {
        if case .success = result { return true }
        return false
    }
}
