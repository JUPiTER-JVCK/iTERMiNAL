import AppKit
import Foundation

/// Executes API commands against the live app state.
///
/// Every method here runs on the main queue (the server hops onto it before
/// calling `handle`), because it touches AppKit views and the workspace store
/// directly. Commands that finish asynchronously — anything driving the web
/// view — call the completion later rather than blocking.
final class APIRouter {
    static let shared = APIRouter()

    private var store: WorkspaceStore { WorkspaceStore.shared }
    private var settings: AppSettings { AppSettings.shared }

    static let commands: [String] = [
        "help", "ping", "app.info",
        "subscribe", "unsubscribe",
        "connection.list",
        "workspace.list", "workspace.create",
        "tab.list", "tab.create", "tab.select", "tab.close",
        "pane.list", "pane.split", "pane.close",
        "terminal.send", "terminal.capture", "terminal.reconnect",
        "browser.open", "browser.navigate", "browser.eval", "browser.click",
        "browser.fill", "browser.text", "browser.html", "browser.wait",
        "browser.screenshot",
        "files.list",
    ]

    func handle(_ request: APIRequest, completion: @escaping (APIResponse) -> Void) {
        let id = request.id

        func ok(_ result: [String: Any] = [:]) { completion(.success(id: id, result)) }
        func fail(_ message: String) { completion(.failure(id: id, message: message)) }

        switch request.command {
        case "help":
            ok(["commands": Self.commands])

        case "ping":
            ok(["pong": true])

        case "app.info":
            ok([
                "name": "iTERMiNAL",
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
                "workspaces": store.workspaces.count,
                "tabs": store.workspaces.reduce(0) { $0 + $1.tabs.count },
                "gpuRendering": settings.useGPURendering,
            ])

        // MARK: Workspaces and tabs

        case "workspace.list":
            ok(["workspaces": store.workspaces.map(Self.describe)])

        case "workspace.create":
            let name = request.string("name")
            store.newWorkspace(named: name)
            guard let created = store.workspaces.last else { return fail("Could not create workspace.") }
            ok(["workspace": Self.describe(created)])

        case "tab.list":
            ok([
                "tabs": store.workspaces.flatMap { workspace in
                    workspace.tabs.map { Self.describe($0, workspaceName: workspace.name) }
                },
                "selected": store.selectedTabID?.uuidString ?? "",
            ])

        case "tab.create":
            let workspace = request.string("workspace").flatMap { name in
                store.workspaces.first { $0.name == name || $0.id.uuidString == name }
            }
            var kind = SessionKind.localShell
            if let identifier = request.string("connection") ?? (request.string("kind") == "ssh" ? request.string("host") : nil) {
                guard let connection = settings.connection(withID: identifier) else {
                    return fail("No saved connection named \(identifier).")
                }
                kind = .remote(connection.id)
            }
            let tab = store.newTab(in: workspace, directory: request.string("directory"), kind: kind)
            ok(["tab": Self.describe(tab, workspaceName: workspace?.name)])

        case "connection.list":
            ok(["connections": settings.sshConnections.map { connection in
                [
                    "id": connection.id.uuidString,
                    "name": connection.name,
                    "host": connection.host,
                    "port": connection.port,
                    "username": connection.username,
                    "transport": connection.transport.rawValue,
                ] as [String: Any]
            }])

        case "tab.select":
            guard let identifier = request.string("id"),
                  let tab = store.tab(withID: identifier) else { return fail("No such tab.") }
            store.selectedTabID = tab.id
            ok(["tab": Self.describe(tab, workspaceName: nil)])

        case "tab.close":
            if let identifier = request.string("id") {
                guard let tab = store.tab(withID: identifier) else { return fail("No such tab.") }
                store.closeTab(tab)
            } else {
                store.closeSelectedTab()
            }
            ok()

        // MARK: Panes

        case "pane.list":
            guard let tab = store.selectedTab else { return fail("No tab is open.") }
            ok(["panes": Self.describePanes(tab.root)])

        case "pane.split":
            let direction: SplitDirection = (request.string("direction") == "vertical") ? .vertical : .horizontal
            let kind: PaneKind
            switch request.string("kind") ?? "terminal" {
            case "browser": kind = .browser
            case "files": kind = .files
            default: kind = .terminal
            }
            var connectionID: UUID?
            if let identifier = request.string("connection") {
                guard let connection = settings.connection(withID: identifier) else {
                    return fail("No saved connection named \(identifier).")
                }
                connectionID = connection.id
            }
            guard let node = store.splitFocusedPane(direction, kind: kind, connection: connectionID) else {
                return ok()
            }
            // Hand back the new pane so scripts can target it deterministically.
            ok(["pane": Self.describePanes(node).first ?? [:]])

        case "pane.close":
            store.closeFocusedPane()
            ok()

        // MARK: Terminal

        case "terminal.send":
            guard settings.apiAllowTerminalInput else {
                return fail("Terminal input over the API is disabled in Settings → Security.")
            }
            guard let text = request.string("text") else { return fail("Missing \"text\".") }
            let session = request.string("session").flatMap { store.session(withIdentifier: $0) } ?? store.focusedSession
            guard let session else { return fail("No terminal session available.") }
            let payload = request.bool("newline", default: false) ? text + "\n" : text
            session.send(text: payload)
            ok(["session": session.id.uuidString])

        case "terminal.reconnect":
            let session = request.string("session").flatMap { store.session(withIdentifier: $0) } ?? store.focusedSession
            guard let session else { return fail("No terminal session available.") }
            session.reconnect()
            ok(["session": session.id.uuidString, "running": session.isRunning])

        case "terminal.capture":
            let session = request.string("session").flatMap { store.session(withIdentifier: $0) } ?? store.focusedSession
            guard let session else { return fail("No terminal session available.") }
            ok(["session": session.id.uuidString, "text": session.captureVisibleText()])

        // MARK: Browser

        case "browser.open":
            guard settings.apiAllowBrowserControl else { return fail(Self.browserDisabled) }
            let direction: SplitDirection = (request.string("direction") == "vertical") ? .vertical : .horizontal
            guard let node = store.splitFocusedPane(direction, kind: .browser),
                  let browser = node.allBrowsers().first else {
                return fail("Could not open a browser pane.")
            }
            if let url = request.string("url") {
                browser.navigate(to: url) { result in
                    switch result {
                    case .success(let final): ok(["pane": browser.id.uuidString, "url": final])
                    case .failure(let error): fail(error.localizedDescription)
                    }
                }
            } else {
                ok(["pane": browser.id.uuidString])
            }

        case "browser.newTab":
            guard settings.apiAllowBrowserControl else { return fail(Self.browserDisabled) }
            let tab = store.panelBrowserTabs.newTab()
            store.openPanel(.browser)
            if let url = request.string("url") {
                tab.navigate(to: url) { result in
                    switch result {
                    case .success(let final): ok(["pane": tab.id.uuidString, "url": final])
                    case .failure(let error): fail(error.localizedDescription)
                    }
                }
            } else {
                ok(["pane": tab.id.uuidString])
            }

        case "browser.navigate":
            withBrowser(request, fail: fail) { browser in
                guard let url = request.string("url") else { return fail("Missing \"url\".") }
                browser.navigate(to: url) { result in
                    switch result {
                    case .success(let final): ok(["pane": browser.id.uuidString, "url": final])
                    case .failure(let error): fail(error.localizedDescription)
                    }
                }
            }

        case "browser.eval":
            withBrowser(request, fail: fail) { browser in
                guard let script = request.string("script") else { return fail("Missing \"script\".") }
                browser.evaluate(script) { Self.deliver($0, ok: ok, fail: fail) }
            }

        case "browser.click":
            withBrowser(request, fail: fail) { browser in
                guard let selector = request.string("selector") else { return fail("Missing \"selector\".") }
                browser.click(selector: selector) { Self.deliver($0, ok: ok, fail: fail) }
            }

        case "browser.fill":
            withBrowser(request, fail: fail) { browser in
                guard let selector = request.string("selector"),
                      let value = request.string("value") else { return fail("Missing \"selector\" or \"value\".") }
                browser.fill(selector: selector, value: value) { Self.deliver($0, ok: ok, fail: fail) }
            }

        case "browser.text":
            withBrowser(request, fail: fail) { browser in
                browser.text(selector: request.string("selector")) { Self.deliver($0, ok: ok, fail: fail) }
            }

        case "browser.html":
            withBrowser(request, fail: fail) { browser in
                browser.html { Self.deliver($0, ok: ok, fail: fail) }
            }

        case "browser.wait":
            withBrowser(request, fail: fail) { browser in
                guard let selector = request.string("selector") else { return fail("Missing \"selector\".") }
                browser.waitForSelector(selector, timeout: request.double("timeout", default: 10)) {
                    Self.deliver($0, ok: ok, fail: fail)
                }
            }

        case "browser.screenshot":
            withBrowser(request, fail: fail) { browser in
                browser.screenshot { result in
                    switch result {
                    case .success(let data):
                        if let path = request.string("path") {
                            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                            do {
                                try data.write(to: url, options: .atomic)
                                ok(["path": url.path, "bytes": data.count])
                            } catch {
                                fail(error.localizedDescription)
                            }
                        } else {
                            ok(["png": data.base64EncodedString(), "bytes": data.count])
                        }
                    case .failure(let error):
                        fail(error.localizedDescription)
                    }
                }
            }

        // MARK: Files

        case "files.list":
            let provider: FileSystemProvider
            if let connectionID = request.string("connection"),
               let connection = settings.connection(withID: connectionID) {
                provider = SFTPFileSystemProvider(connection: connection)
            } else {
                provider = LocalFileSystemProvider.shared
            }
            let path = request.string("path") ?? provider.defaultPath()
            provider.list(path, showHidden: request.bool("hidden", default: false)) { result in
                switch result {
                case .success(let listing):
                    ok([
                        "path": listing.path,
                        "items": listing.items.map { item in
                            [
                                "name": item.name,
                                "path": item.path,
                                "directory": item.isDirectory,
                                "size": item.size ?? 0,
                            ] as [String: Any]
                        },
                    ])
                case .failure(let error):
                    fail(error.localizedDescription)
                }
            }

        default:
            fail("Unknown command \"\(request.command)\". Try \"help\".")
        }
    }

    // MARK: Helpers

    private static let browserDisabled = "Browser control over the API is disabled in Settings → Security."

    /// Resolves the browser a command targets: an explicit pane id, else the
    /// first browser pane in the current tab, else the panel's active tab.
    ///
    /// The panel is tabbed, so "panel" means whichever tab is in front. With
    /// no tab open there is nothing to drive, and saying so beats silently
    /// creating one behind the user's back.
    private func withBrowser(
        _ request: APIRequest,
        fail: @escaping (String) -> Void,
        body: (BrowserModel) -> Void
    ) {
        guard settings.apiAllowBrowserControl else {
            fail(Self.browserDisabled)
            return
        }
        if let identifier = request.string("pane") {
            if identifier == "panel" {
                guard let active = store.panelBrowserTabs.active else {
                    fail(Self.noPanelTab)
                    return
                }
                body(active)
                return
            }
            guard let browser = store.browser(withIdentifier: identifier) else {
                fail("No browser pane with id \(identifier).")
                return
            }
            body(browser)
            return
        }
        if let browser = store.selectedTab?.root.allBrowsers().first {
            body(browser)
            return
        }
        guard let active = store.panelBrowserTabs.active else {
            fail(Self.noPanelTab)
            return
        }
        body(active)
    }

    private static let noPanelTab =
        "No browser tab is open. Open the browser panel or call browser.newTab first."


    private static func deliver(
        _ result: Result<String, Error>,
        ok: ([String: Any]) -> Void,
        fail: (String) -> Void
    ) {
        switch result {
        case .success(let value): ok(["value": value])
        case .failure(let error): fail(error.localizedDescription)
        }
    }

    private static func describe(_ workspace: Workspace) -> [String: Any] {
        [
            "id": workspace.id.uuidString,
            "name": workspace.name,
            "tabs": workspace.tabs.map { describe($0, workspaceName: workspace.name) },
        ]
    }

    private static func describe(_ tab: WorkspaceTab, workspaceName: String?) -> [String: Any] {
        var payload: [String: Any] = [
            "id": tab.id.uuidString,
            "title": tab.displayName,
        ]
        if let workspaceName { payload["workspace"] = workspaceName }
        if let session = tab.primarySession {
            payload["session"] = session.id.uuidString
            payload["directory"] = session.currentDirectory
            payload["running"] = session.isRunning
            payload["remote"] = session.isRemote
            if let branch = session.gitBranch { payload["branch"] = branch }
            if let error = session.launchError { payload["error"] = error }
        }
        return payload
    }

    private static func describePanes(_ node: PaneNode) -> [[String: Any]] {
        switch node.content {
        case .terminal(let session):
            return [[
                "kind": "terminal",
                "id": session.id.uuidString,
                "directory": session.currentDirectory,
                "running": session.isRunning,
                "remote": session.isRemote,
            ]]
        case .browser(let browser):
            return [[
                "kind": "browser",
                "id": browser.id.uuidString,
                "url": browser.urlText,
                "title": browser.pageTitle,
            ]]
        case .files(let files):
            return [[
                "kind": "files",
                "id": files.id.uuidString,
                "path": files.directory,
                "remote": files.isRemote,
            ]]
        case .split(let direction, let children):
            return children.flatMap { child -> [[String: Any]] in
                describePanes(child).map { pane in
                    var copy = pane
                    copy["split"] = direction.rawValue
                    return copy
                }
            }
        }
    }
}
