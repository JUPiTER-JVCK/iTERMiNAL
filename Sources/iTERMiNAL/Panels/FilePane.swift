import SwiftUI
import AppKit

/// Finder-style directory listing: navigable, sorted folders-first, with
/// Quick-Look-adjacent actions (open, reveal in Finder, copy path).
final class FileBrowserModel: ObservableObject {
    struct FileEntry: Identifiable, Hashable {
        let url: URL
        let name: String
        let isDirectory: Bool
        let size: Int64?
        let modified: Date?
        var id: URL { url }
    }

    @Published private(set) var directory: URL
    @Published private(set) var entries: [FileEntry] = []
    @Published var selection: URL?

    private var history: [URL] = []

    var canGoBack: Bool { !history.isEmpty }

    init(path: String? = nil) {
        let resolved = path ?? NSHomeDirectory()
        directory = URL(fileURLWithPath: resolved, isDirectory: true)
        reload()
    }

    func open(_ entry: FileEntry) {
        if entry.isDirectory {
            navigate(to: entry.url)
        } else {
            NSWorkspace.shared.open(entry.url)
        }
    }

    func navigate(to url: URL) {
        guard url != directory else {
            reload()
            return
        }
        history.append(directory)
        directory = url
        selection = nil
        reload()
        WorkspaceStore.shared.scheduleSave()
    }

    func goBack() {
        guard let previous = history.popLast() else { return }
        directory = previous
        selection = nil
        reload()
    }

    func goUp() {
        let parent = directory.deletingLastPathComponent()
        guard parent != directory else { return }
        navigate(to: parent)
    }

    func revealInFinder() {
        let target = selection ?? directory
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    var abbreviatedPath: String {
        let path = directory.path
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    func reload() {
        let target = directory
        let showHidden = AppSettings.shared.showHiddenFiles
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: target,
                includingPropertiesForKeys: keys,
                options: showHidden ? [] : [.skipsHiddenFiles]
            )) ?? []

            let entries = contents.map { url -> FileEntry in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return FileEntry(
                    url: url,
                    name: url.lastPathComponent,
                    isDirectory: values?.isDirectory ?? false,
                    size: (values?.fileSize).map(Int64.init),
                    modified: values?.contentModificationDate
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }

            DispatchQueue.main.async {
                guard let self, self.directory == target else { return }
                self.entries = entries
            }
        }
    }
}

struct FilePaneView: View {
    @ObservedObject var model: FileBrowserModel
    @EnvironmentObject private var store: WorkspaceStore
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

                Text(model.abbreviatedPath)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(theme.textPrimary)

                Spacer(minLength: 8)

                Button {
                    if let directory = store.focusedSession?.currentDirectory {
                        model.navigate(to: URL(fileURLWithPath: directory))
                    }
                } label: {
                    Image(systemName: "terminal")
                }
                .buttonStyle(.plain)
                .help("Go to the focused terminal's directory")

                Button(action: model.reload) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)

                Button(action: model.revealInFinder) {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")
            }
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            if model.entries.isEmpty {
                VStack {
                    Spacer()
                    Text("Empty folder")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(model.entries, selection: $model.selection) { entry in
                    FileRowView(entry: entry, dateFormatter: Self.dateFormatter)
                        .tag(entry.url)
                        .contentShape(Rectangle())
                        .gesture(TapGesture(count: 2).onEnded { model.open(entry) })
                        .simultaneousGesture(TapGesture().onEnded { model.selection = entry.url })
                        .contextMenu {
                            Button("Open") { model.open(entry) }
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                            }
                            Button("Copy Path") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry.url.path, forType: .string)
                            }
                        }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .background(theme.background)
    }
}

private struct FileRowView: View {
    let entry: FileBrowserModel.FileEntry
    let dateFormatter: DateFormatter

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                .resizable()
                .frame(width: 16, height: 16)
            Text(entry.name)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let modified = entry.modified {
                Text(dateFormatter.string(from: modified))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 1)
    }
}
