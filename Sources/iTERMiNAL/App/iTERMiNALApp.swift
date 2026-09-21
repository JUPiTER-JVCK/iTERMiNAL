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
                // Without this the accent setting governed almost nothing:
                // every stock control — toggles, sliders, pickers, list
                // selection — falls back to the *system* accent unless the
                // hierarchy is tinted.
                .tint(settings.accentColor)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { AppCommands() }

        Settings {
            SettingsRootView()
                .environmentObject(settings)
                .environmentObject(store)
                .preferredColorScheme(settings.preferredColorScheme)
                .tint(settings.accentColor)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // NSApp exists by now, which it does not when AppSettings is first
        // constructed — so the stored choice is applied here rather than in
        // the initialiser that loads it.
        AppSettings.shared.applyAppearance()
        // The scripting API only listens when the user has enabled it.
        LocalAPIServer.shared.applyEnabledState(AppSettings.shared.localAPIEnabled)
    }

    func applicationWillTerminate(_ notification: Notification) {
        LocalAPIServer.shared.stop()
        WorkspaceStore.shared.saveNow()
        WorkspaceStore.shared.terminateAllSessions()
    }
}

struct AppCommands: Commands {
    /// Observed so the composer item's title follows its state. A Commands
    /// body is only re-evaluated for state it actually observes; reading the
    /// singleton directly would freeze the title at whatever it said when the
    /// menu was first built.
    @ObservedObject private var settings = AppSettings.shared

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

        CommandGroup(after: .toolbar) {
            Button("Command Palette") {
                WorkspaceStore.shared.showCommandPalette = true
            }
            .keyboardShortcut("k", modifiers: .command)

            // The reference design uses ⌘P for the palette; keep both, since
            // the app has nothing to print.
            Button("Command Palette (⌘P)") {
                WorkspaceStore.shared.showCommandPalette = true
            }
            .keyboardShortcut("p", modifiers: .command)
        }

        CommandMenu("Terminal") {
            // Bound to the same 9...24 range the Appearance slider uses, so
            // the two can't disagree about what a legal size is.
            Button("Bigger Text") {
                settings.terminalFontSize = min(24, settings.terminalFontSize + 1)
            }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(settings.terminalFontSize >= 24)

            Button("Smaller Text") {
                settings.terminalFontSize = max(9, settings.terminalFontSize - 1)
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(settings.terminalFontSize <= 9)

            Button("Actual Size") {
                settings.terminalFontSize = 13
            }
            .keyboardShortcut("0", modifiers: .command)

            Divider()

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
            Button("Toggle Terminal Dock") {
                WorkspaceStore.shared.toggleBottomDock()
            }
            .keyboardShortcut("j", modifiers: .command)

            Divider()

            Button("Toggle Browser Panel") {
                WorkspaceStore.shared.togglePanel(.browser)
            }
            .keyboardShortcut("b", modifiers: [.command, .option])

            Button("Toggle Files Panel") {
                WorkspaceStore.shared.togglePanel(.files)
            }
            .keyboardShortcut("f", modifiers: [.command, .option])

            Divider()

            Button("Focus Composer") {
                WorkspaceStore.shared.focusComposer()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Button(settings.composerCollapsed ? "Expand Composer" : "Minimise Composer") {
                withAnimation(Motion.panel) {
                    settings.composerCollapsed.toggle()
                }
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])

            Divider()

            Button("Task Manager") {
                WorkspaceStore.shared.detailMode = .tasks
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
        }

        SidebarCommands()
    }
}
