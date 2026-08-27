import Foundation

enum SplitDirection: String, Codable {
    /// Side-by-side panes (rendered with HSplitView).
    case horizontal
    /// Stacked panes (rendered with VSplitView).
    case vertical
}

enum PaneKind {
    case terminal, browser, files
}

/// The content of one node in a tab's layout tree: either a leaf pane or a
/// split holding child nodes.
enum PaneContent {
    case terminal(TerminalSession)
    case browser(BrowserModel)
    case files(FileBrowserModel)
    case split(SplitDirection, [PaneNode])
}

final class PaneNode: ObservableObject, Identifiable {
    let id: UUID
    @Published var content: PaneContent

    init(id: UUID = UUID(), content: PaneContent) {
        self.id = id
        self.content = content
    }
}

final class WorkspaceTab: ObservableObject, Identifiable {
    let id: UUID
    @Published var customName: String?
    @Published var root: PaneNode

    init(id: UUID = UUID(), customName: String? = nil, root: PaneNode) {
        self.id = id
        self.customName = customName
        self.root = root
    }

    var primarySession: TerminalSession? {
        root.firstTerminal()
    }

    var displayName: String {
        if let customName, !customName.isEmpty { return customName }
        return primarySession?.displayTitle ?? "Terminal"
    }
}

final class Workspace: ObservableObject, Identifiable {
    let id: UUID
    @Published var name: String
    @Published var tabs: [WorkspaceTab]

    init(id: UUID = UUID(), name: String, tabs: [WorkspaceTab] = []) {
        self.id = id
        self.name = name
        self.tabs = tabs
    }
}

// MARK: - Tree traversal

extension PaneNode {
    func firstTerminal() -> TerminalSession? {
        switch content {
        case .terminal(let session):
            return session
        case .split(_, let children):
            for child in children {
                if let session = child.firstTerminal() { return session }
            }
            return nil
        case .browser, .files:
            return nil
        }
    }

    func allSessions() -> [TerminalSession] {
        switch content {
        case .terminal(let session):
            return [session]
        case .split(_, let children):
            return children.flatMap { $0.allSessions() }
        case .browser, .files:
            return []
        }
    }

    /// The leaf node whose terminal session has the given id.
    func leaf(containingSessionID sessionID: UUID) -> PaneNode? {
        switch content {
        case .terminal(let session):
            return session.id == sessionID ? self : nil
        case .split(_, let children):
            for child in children {
                if let node = child.leaf(containingSessionID: sessionID) { return node }
            }
            return nil
        case .browser, .files:
            return nil
        }
    }

    /// The split node that directly contains `target` as a child.
    func parent(of target: PaneNode) -> PaneNode? {
        guard case .split(_, let children) = content else { return nil }
        if children.contains(where: { $0 === target }) { return self }
        for child in children {
            if let found = child.parent(of: target) { return found }
        }
        return nil
    }
}

// MARK: - Persistence snapshots

struct AppStateSnapshot: Codable {
    var workspaces: [WorkspaceSnapshot]
    var selectedTabID: UUID?
}

struct WorkspaceSnapshot: Codable {
    var id: UUID
    var name: String
    var tabs: [TabSnapshot]
}

struct TabSnapshot: Codable {
    var id: UUID
    var customName: String?
    var root: PaneSnapshot
}

indirect enum PaneSnapshot: Codable {
    case terminal(directory: String?)
    case browser(url: String?)
    case files(path: String?)
    case split(direction: SplitDirection, children: [PaneSnapshot])
}

extension PaneNode {
    func snapshot() -> PaneSnapshot {
        switch content {
        case .terminal(let session):
            return .terminal(directory: session.currentDirectory)
        case .browser(let browser):
            return .browser(url: browser.urlText)
        case .files(let files):
            return .files(path: files.directory.path)
        case .split(let direction, let children):
            return .split(direction: direction, children: children.map { $0.snapshot() })
        }
    }

    static func restore(_ snapshot: PaneSnapshot) -> PaneNode {
        switch snapshot {
        case .terminal(let directory):
            return PaneNode(content: .terminal(TerminalSession(initialDirectory: directory)))
        case .browser(let url):
            return PaneNode(content: .browser(BrowserModel(initialURL: url)))
        case .files(let path):
            return PaneNode(content: .files(FileBrowserModel(path: path)))
        case .split(let direction, let children):
            return PaneNode(content: .split(direction, children.map { PaneNode.restore($0) }))
        }
    }
}

extension WorkspaceTab {
    func snapshot() -> TabSnapshot {
        TabSnapshot(id: id, customName: customName, root: root.snapshot())
    }

    convenience init(snapshot: TabSnapshot) {
        self.init(id: snapshot.id, customName: snapshot.customName, root: PaneNode.restore(snapshot.root))
    }
}

extension Workspace {
    func snapshot() -> WorkspaceSnapshot {
        WorkspaceSnapshot(id: id, name: name, tabs: tabs.map { $0.snapshot() })
    }

    convenience init(snapshot: WorkspaceSnapshot) {
        self.init(id: snapshot.id, name: snapshot.name, tabs: snapshot.tabs.map { WorkspaceTab(snapshot: $0) })
    }
}
