import SwiftUI
import AppKit

@main
struct ITerminalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = AppSettings.shared
    @StateObject private var store = WorkspaceStore.shared

    var body: some Scene {
        // A single Window scene: terminal views are live AppKit views owned
        // by their sessions and cannot appear in two windows at once.
        Window("iTERMiNAL", id: "main") {
            MainWindowView()
                .environmentObject(settings)
                .environmentObject(store)
                .preferredColorScheme(settings.preferredColorScheme)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { AppCommands() }

        Settings {
            SettingsRootView()
                .environmentObject(settings)
                .environmentObject(store)
                .preferredColorScheme(settings.preferredColorScheme)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        WorkspaceStore.shared.saveNow()
        WorkspaceStore.shared.terminateAllSessions()
    }
}

struct AppCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Terminal Tab") {
                WorkspaceStore.shared.newTab()
            }
            .keyboardShortcut("t", modifiers: .command)

            Button("New Workspace") {
                WorkspaceStore.shared.newWorkspace()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandMenu("Terminal") {
            Button("Split Right") {
                WorkspaceStore.shared.splitFocusedPane(.horizontal, kind: .terminal)
            }
            .keyboardShortcut("d", modifiers: .command)

            Button("Split Down") {
                WorkspaceStore.shared.splitFocusedPane(.vertical, kind: .terminal)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Button("Split with Browser") {
                WorkspaceStore.shared.splitFocusedPane(.horizontal, kind: .browser)
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])

            Button("Split with Files") {
                WorkspaceStore.shared.splitFocusedPane(.horizontal, kind: .files)
            }

            Divider()

            Button("Close Pane") {
                WorkspaceStore.shared.closeFocusedPane()
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])

            Button("Close Tab") {
                WorkspaceStore.shared.closeSelectedTab()
            }
            .keyboardShortcut("w", modifiers: [.command, .option])
        }

        CommandMenu("Panels") {
            Button("Toggle Browser Panel") {
                WorkspaceStore.shared.togglePanel(.browser)
            }
            .keyboardShortcut("b", modifiers: [.command, .option])

            Button("Toggle Files Panel") {
                WorkspaceStore.shared.togglePanel(.files)
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
        }

        SidebarCommands()
    }
}
