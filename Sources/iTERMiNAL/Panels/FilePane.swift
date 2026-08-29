import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Finder-style directory listing backed by a `FileSystemProvider`, so the
/// same pane browses this Mac or a remote host over SFTP. Remote files are
/// fetched to a temporary copy on demand for preview/open, and edits are
/// pushed back with an explicit upload.
final class FileBrowserModel: ObservableObject, Identifiable {
    let id = UUID()

    @Published private(set) var provider: FileSystemProvider
    @Published private(set) var directory: String
    @Published private(set) var items: [FileItem] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var selection: String?
    @Published private(set) var transferNote: String?

    private var history: [String] = []

    var canGoBack: Bool { !history.isEmpty }
    var isRemote: Bool { provider.isRemote }
    var connectionID: String? { provider.isRemote ? provider.identifier : nil }

    init(path: String? = nil, connectionID: String? = nil) {
        let resolvedProvider = Self.makeProvider(connectionID: connectionID)
        provider = resolvedProvider
        directory = path ?? resolvedProvider.defaultPath()
        reload()
    }

    private static func makeProvider(connectionID: String?) -> FileSystemProvider {
        guard let connectionID, connectionID != "local",
              let connection = AppSettings.shared.connection(withID: connectionID) else {
            return LocalFileSystemProvider.shared
        }
        return SFTPFileSystemProvider(connection: connection)
    }

    // MARK: Navigation

    func reload() {
        isLoading = true
        errorMessage = nil
        let target = directory
        provider.list(target, showHidden: AppSettings.shared.showHiddenFiles) { [weak self] result in
            guard let self, self.directory == target else { return }
            self.isLoading = false
            switch result {
            case .success(let listing):
                self.directory = listing.path
                self.items = listing.items
            case .failure(let error):
                self.items = []
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func navigate(to path: String) {
        guard path != directory else {
            reload()
            return
        }
        history.append(directory)
        directory = path
        selection = nil
        reload()
        WorkspaceStore.shared.scheduleSave()
    }

    func goBack() {
        guard let previous = history.popLast() else { return }
        directory = previous
        selection = nil
        reload()
        WorkspaceStore.shared.scheduleSave()
    }

    func goUp() {
        let parent = provider.parentPath(of: directory)
        guard parent != directory else { return }
        navigate(to: parent)
    }

    func switchTo(connectionID: String?) {
        provider = Self.makeProvider(connectionID: connectionID)
        history.removeAll()
        directory = provider.defaultPath()
        selection = nil
        items = []
        reload()
        WorkspaceStore.shared.scheduleSave()
    }

    // MARK: Actions

    func open(_ item: FileItem) {
        if item.isDirectory {
            navigate(to: item.path)
            return
        }
        if provider.isRemote {
            fetchToTemporary(item) { url in
                NSWorkspace.shared.open(url)
            }
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
        }
    }

    /// Copies a remote file into the user's Downloads folder.
    func download(_ item: FileItem) {
        guard provider.isRemote else { return }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        let destination = downloads.appendingPathComponent(item.name)
        transferNote = "Downloading \(item.name)…"
        provider.download(item.path, to: destination) { [weak self] result in
            switch result {
            case .success(let url):
                self?.transferNote = "Saved to \(url.path)"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            case .failure(let error):
                self?.transferNote = nil
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    /// Prompts for local files and uploads them into the current directory.
    func promptUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        guard panel.runModal() == .OK else { return }
        upload(panel.urls)
    }

    func upload(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        var remaining = urls.count
        transferNote = "Uploading \(remaining) item\(remaining == 1 ? "" : "s")…"
        for url in urls {
            provider.upload(url, toDirectory: directory) { [weak self] result in
                remaining -= 1
                if case .failure(let error) = result {
                    self?.errorMessage = error.localizedDescription
                }
                if remaining == 0 {
                    self?.transferNote = nil
                    self?.reload()
                }
            }
        }
    }

    func delete(_ item: FileItem) {
        provider.delete(item) { [weak self] result in
            switch result {
            case .success:
                self?.reload()
            case .failure(let error):
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func revealInFinder() {
        guard !provider.isRemote else { return }
        let target = selection ?? directory
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)])
    }

    func copyPath(_ item: FileItem) {
        NSPasteboard.general.clearContents()
        let value = provider.isRemote
            ? "\(sftpURLPrefix)\(item.path)"
            : item.path
        NSPasteboard.general.setString(value, forType: .string)
    }

    private var sftpURLPrefix: String {
        guard let sftp = provider as? SFTPFileSystemProvider else { return "" }
        return "sftp://\(sftp.connection.destination)"
    }

    private func fetchToTemporary(_ item: FileItem, completion: @escaping (URL) -> Void) {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("iTERMiNAL", isDirectory: true)
        try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let destination = temporary.appendingPathComponent(item.name)
        transferNote = "Fetching \(item.name)…"
        provider.download(item.path, to: destination) { [weak self] result in
            self?.transferNote = nil
            switch result {
            case .success(let url):
                completion(url)
            case .failure(let error):
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    var abbreviatedPath: String {
        guard !provider.isRemote else { return directory }
        let home = NSHomeDirectory()
        if directory == home { return "~" }
        if directory.hasPrefix(home + "/") {
            return "~" + directory.dropFirst(home.count)
        }
        return directory
    }
}

struct FilePaneView: View {
    @ObservedObject var model: FileBrowserModel
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        VStack(spacing: 0) {
            toolbar(theme: theme)
            FadedDivider()
            content(theme: theme)
            if let note = model.transferNote {
                statusStrip(text: note, theme: theme, isError: false)
            } else if let error = model.errorMessage {
                statusStrip(text: error, theme: theme, isError: true)
            }
        }
        .background(theme.background)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadDroppedFiles(providers)
            return true
        }
    }

    private func toolbar(theme: Theme) -> some View {
        HStack(spacing: 8) {
            Button(action: model.goBack) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .disabled(!model.canGoBack)

            Button(action: model.goUp) {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(.plain)

            Menu {
                Button {
                    model.switchTo(connectionID: nil)
                } label: {
                    Label("This Mac", systemImage: "desktopcomputer")
                }
                if !settings.sshConnections.isEmpty {
                    Divider()
                    ForEach(settings.sshConnections) { connection in
                        Button {
                            model.switchTo(connectionID: connection.id.uuidString)
                        } label: {
                            Label(connection.name, systemImage: "network")
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: model.isRemote ? "network" : "desktopcomputer")
                        .font(.system(size: 10))
                    Text(model.provider.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Text(model.abbreviatedPath)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.head)
                .foregroundStyle(theme.textPrimary)

            Spacer(minLength: 8)

            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            if !model.isRemote {
                Button {
                    // Read the shell's directory now rather than trusting the
                    // last value: without an OSC 7 hook the cached one is
                    // whatever the session launched in, which is what made
                    // this button look broken.
                    guard let session = store.focusedSession else { return }
                    session.refreshDirectoryFromProcess()
                    model.navigate(to: session.currentDirectory)
                } label: {
                    Image(systemName: "terminal")
                }
                .buttonStyle(.plain)
                .help("Go to the focused terminal's directory")
            }

            if model.isRemote {
                Button(action: model.promptUpload) {
                    Image(systemName: "arrow.up.doc")
                }
                .buttonStyle(.plain)
                .help("Upload files here")
            }

            Button(action: model.reload) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)

            if !model.isRemote {
                Button(action: model.revealInFinder) {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")
            }
        }
        .foregroundStyle(theme.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func content(theme: Theme) -> some View {
        if model.items.isEmpty {
            VStack {
                Spacer()
                Text(model.isLoading ? "Loading…" : "Empty folder")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List(model.items, selection: $model.selection) { item in
                FileRowView(item: item, dateFormatter: Self.dateFormatter)
                    .tag(item.path)
                    .contentShape(Rectangle())
                    .gesture(TapGesture(count: 2).onEnded { model.open(item) })
                    .simultaneousGesture(TapGesture().onEnded { model.selection = item.path })
                    .contextMenu {
                        Button("Open") { model.open(item) }
                        if model.isRemote {
                            Button("Download to Downloads") { model.download(item) }
                        } else {
                            // A file opens its containing directory: `cd` to a
                            // file is not a thing, and the directory is what
                            // you actually wanted to be in.
                            Button("Open in Terminal") {
                                store.newTab(directory: item.isDirectory
                                    ? item.path
                                    : (item.path as NSString).deletingLastPathComponent)
                            }
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                            }
                        }
                        Button("Copy Path") { model.copyPath(item) }
                        Divider()
                        Button(model.isRemote ? "Delete" : "Move to Trash", role: .destructive) {
                            model.delete(item)
                        }
                    }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private func statusStrip(text: String, theme: Theme, isError: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isError ? "exclamationmark.triangle" : "arrow.left.arrow.right")
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 11))
                .lineLimit(2)
            Spacer()
            if isError {
                Button("Dismiss") { model.errorMessage = nil }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
            }
        }
        .foregroundStyle(isError ? Color.red : theme.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.surface)
    }

    private func loadDroppedFiles(_ providers: [NSItemProvider]) {
        // loadObject calls back on an arbitrary queue, so the shared array
        // needs a lock — appending from several at once would corrupt it.
        let collected = DroppedURLs()
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { collected.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            model.upload(collected.urls)
        }
    }
}

/// Lock-guarded accumulator for drag-and-drop, whose callbacks arrive on
/// whatever queue the item provider chooses.
private final class DroppedURLs {
    private let lock = NSLock()
    private var storage: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        storage.append(url)
        lock.unlock()
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private struct FileRowView: View {
    let item: FileItem
    let dateFormatter: DateFormatter

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                .font(.system(size: 12))
                .foregroundStyle(item.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 16)
            Text(item.name)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let modified = item.modified {
                Text(dateFormatter.string(from: modified))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 1)
    }
}
