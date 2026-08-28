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
    /// Pinned tabs also appear in the sidebar's Pinned section.
    @Published var isPinned: Bool

    init(id: UUID = UUID(), customName: String? = nil, isPinned: Bool = false, root: PaneNode) {
        self.id = id
        self.customName = customName
        self.isPinned = isPinned
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

    func allBrowsers() -> [BrowserModel] {
        switch content {
        case .browser(let browser):
            return [browser]
        case .split(_, let children):
            return children.flatMap { $0.allBrowsers() }
        case .terminal, .files:
            return []
        }
    }

    /// True when this node holds content directly rather than a split. A tab
    /// whose root is a leaf has exactly one pane, so it needs no focus ring.
    var isLeaf: Bool {
        if case .split = content { return false }
        return true
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
    /// Optional so older state files still decode.
    var recents: [RecentSession]?
    /// Also optional, for the same reason.
    var panels: PanelStateSnapshot?
}

/// The surrounding layout — which panels were up and what the dock held.
///
/// Dock terminals are recorded by working directory rather than by process:
/// a shell cannot outlive a quit, so restoring means starting fresh ones
/// where the old ones were.
struct PanelStateSnapshot: Codable {
    var openPanels: [String]
    var frontPanel: String?
    var rightRegionOpen: Bool
    var bottomDockOpen: Bool
    var dockDirectories: [String]
    var rightPanelWidth: Double?
    var bottomDockHeight: Double?
}

/// A session the user closed, kept so it can be reopened from the sidebar.
struct RecentSession: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var directory: String
    var connection: String?
    var closedAt: Date

    var isRemote: Bool { connection != nil }
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
    /// Optional so layouts saved before pinning existed still decode.
    var isPinned: Bool?
}

indirect enum PaneSnapshot: Codable {
    case terminal(directory: String?, connection: String?)
    case browser(url: String?)
    case files(path: String?, connection: String?)
    case split(direction: SplitDirection, children: [PaneSnapshot])
}

extension PaneNode {
    func snapshot() -> PaneSnapshot {
        switch content {
        case .terminal(let session):
            return .terminal(
                directory: session.currentDirectory,
                connection: session.kind.connectionID?.uuidString
            )
        case .browser(let browser):
            return .browser(url: browser.urlText)
        case .files(let files):
            return .files(path: files.directory, connection: files.connectionID)
        case .split(let direction, let children):
            return .split(direction: direction, children: children.map { $0.snapshot() })
        }
    }

    static func restore(_ snapshot: PaneSnapshot) -> PaneNode {
        switch snapshot {
        case .terminal(let directory, let connection):
            // A remote pane restores as a remote pane and redials on launch.
            let kind: SessionKind = connection
                .flatMap { UUID(uuidString: $0) }
                .map { SessionKind.remote($0) } ?? .localShell
            return PaneNode(content: .terminal(
                TerminalSession(kind: kind, initialDirectory: directory)
            ))
        case .browser(let url):
            return PaneNode(content: .browser(BrowserModel(initialURL: url)))
        case .files(let path, let connection):
            return PaneNode(content: .files(FileBrowserModel(path: path, connectionID: connection)))
        case .split(let direction, let children):
            return PaneNode(content: .split(direction, children.map { PaneNode.restore($0) }))
        }
    }
}

extension WorkspaceTab {
    func snapshot() -> TabSnapshot {
        TabSnapshot(id: id, customName: customName, root: root.snapshot(), isPinned: isPinned)
    }

    convenience init(snapshot: TabSnapshot) {
        self.init(
            id: snapshot.id,
            customName: snapshot.customName,
            isPinned: snapshot.isPinned ?? false,
            root: PaneNode.restore(snapshot.root)
        )
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
