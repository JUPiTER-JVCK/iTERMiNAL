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
                // What every view draws its chrome in; see `EnvironmentValues.appThemeID`.
                .environment(\.appThemeID, settings.appThemeID)
                // Without this the accent setting governed almost nothing:
                // every stock control — toggles, sliders, pickers, list
                // selection — falls back to the *system* accent unless the
                // hierarchy is tinted.
                .tint(settings.accentColor)
                // Nil for System, which leaves every font as it was drawn.
                .fontDesign(settings.uiFontDesign.design)
        }
        // Hides the title and makes the bar transparent. It does not remove
        // the title-bar-height safe area SwiftUI still insets content below —
        // `MainWindowView.framelessWindow()` does that, and the same call in
        // SettingsRootView does it for the settings window, which this scene
        // modifier cannot reach.
        //
        // `.windowToolbarStyle` is gone with no replacement: this window has no
        // toolbar for it to style.
        .windowStyle(.hiddenTitleBar)
        .commands { AppCommands() }

        // One window per remote desktop; the value is the session's id. Nothing
        // opens one on its own: they are opened from a service, through the main
        // window, and a window restored from a last launch says it has ended.
        WindowGroup("Remote Desktop", for: UUID.self) { $sessionID in
            RemoteDesktopWindow(sessionID: sessionID)
                .preferredColorScheme(settings.preferredColorScheme)
                .environment(\.appThemeID, settings.appThemeID)
        }
        .defaultSize(width: 1024, height: 720)
        // Opened only by `openWindow(value:)`, so it claims no external events —
        // and a folder sent to the app from Finder or the Dock is one, which
        // `AppDelegate.application(_:open:)` answers by opening tabs.
        .handlesExternalEvents(matching: [])

        Settings {
            SettingsRootView()
                .environmentObject(settings)
                .environmentObject(store)
                .preferredColorScheme(settings.preferredColorScheme)
                .environment(\.appThemeID, settings.appThemeID)
                .tint(settings.accentColor)
                .fontDesign(settings.uiFontDesign.design)
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
        // Forwards a person marked "start when iTERMiNAL opens".
        SavedTunnelRunner.shared.startAutomatic(settings: AppSettings.shared)
        // The Services menu's "New iTERMiNAL Tab at Folder".
        FinderIntegration.shared.register()
        // Not in any shipped build: only the Screenshots workflow defines this.
        #if SCREENSHOTS
        ScreenshotMode.startIfRequested()
        #endif
    }

    // A folder dropped on the Dock icon, chosen under Open With in Finder, or
    // given to `open -a iTERMiNAL`. Each gets a tab; a file gets its folder.
    func application(_ application: NSApplication, open urls: [URL]) {
        FinderIntegration.shared.open(urls: urls)
    }

    // Secure keyboard input is held only while this is the active app.
    func applicationDidBecomeActive(_ notification: Notification) {
        SecureKeyboardEntry.shared.refresh(enabled: AppSettings.shared.secureKeyboardEntry)
    }

    func applicationDidResignActive(_ notification: Notification) {
        // Switching away is as good a moment as any to write notes down.
        WorkspaceStore.shared.flushNotes()
        SecureKeyboardEntry.shared.refresh(enabled: AppSettings.shared.secureKeyboardEntry)
    }

    /// A quit with changes in the Bytes panel that are not saved asks first; with none, it does nothing at all.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let bytes = WorkspaceStore.shared.panelBytes
        // A save cut off by a quit leaves the file as it was, but also leaves its half-written copy beside it.
        if bytes.isSaving {
            let waiting = NSAlert()
            waiting.messageText = "\(bytes.fileName) is still being saved"
            waiting.informativeText = "Quit again once the Bytes panel has finished saving it."
            waiting.runModal()
            return .terminateCancel
        }
        guard bytes.isDirty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Save the changes to \(bytes.fileName)?"
        alert.informativeText = "The Bytes panel has changes that are not in the file yet. If you quit without saving them, they are lost."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            guard let why = bytes.saveNow() else { return .terminateNow }
            let failed = NSAlert()
            failed.messageText = "The changes were not saved"
            failed.informativeText = why
            failed.runModal()
            return .terminateCancel
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        SecureKeyboardEntry.shared.release()
        LocalAPIServer.shared.stop()
        // A child `ssh -N` is not stopped by its parent exiting.
        SavedTunnelRunner.shared.stopAll()
        // Notes save on a debounce, so the last thing typed is exactly what a
        // quit would otherwise drop.
        WorkspaceStore.shared.flushNotes()
        WorkspaceStore.shared.flushChats()
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
                WorkspaceStore.shared.openTab()
            }
            .keyboardShortcut("t", modifiers: .command)

            Button("New Space") {
                WorkspaceStore.shared.newWorkspace()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandGroup(after: .toolbar) {
            Button("Command Palette") {
                WorkspaceStore.shared.showCommandPalette = true
            }
            .keyboardShortcut("k", modifiers: .command)

            // Replaces `SidebarCommands()`, which drove the split view this
            // window no longer has. Same shortcut, so it stays where it was.
            Button(settings.railPanelOpen ? "Hide Sidebar" : "Show Sidebar") {
                withAnimation(Motion.panel) { settings.railPanelOpen.toggle() }
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
        }

        // Replaces "iTERMiNAL Help", which has no help book behind it and only
        // ever showed an error.
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") {
                WorkspaceStore.shared.showShortcuts()
            }
            .keyboardShortcut("/", modifiers: .command)
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

            Toggle("Secure Keyboard Entry", isOn: $settings.secureKeyboardEntry)

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

            Button("Split with HTTP Client") {
                WorkspaceStore.shared.splitFocusedPane(.horizontal, kind: .http)
            }

            Divider()

            Button("Close Pane") {
                WorkspaceStore.shared.closeFocusedPane()
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])

            // Not ⌥⌘W: File > Close All holds that, and an item that asks for a
            // key the standard menus already have is given none — this one had
            // no shortcut at all until it moved.
            Button("Close Tab") {
                WorkspaceStore.shared.closeSelectedTab()
            }
            .keyboardShortcut("w", modifiers: [.command, .control])
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

            Button("Toggle Notes Panel") {
                WorkspaceStore.shared.togglePanel(.notes)
            }
            .keyboardShortcut("n", modifiers: [.command, .option])

            Button("Toggle HTTP Client Panel") {
                WorkspaceStore.shared.togglePanel(.http)
            }
            .keyboardShortcut("r", modifiers: [.command, .option])

            Button("Toggle Bytes Panel") {
                WorkspaceStore.shared.togglePanel(.bytes)
            }
            .keyboardShortcut("y", modifiers: [.command, .option])

            Button("Toggle Byte Tools Panel") {
                WorkspaceStore.shared.togglePanel(.byteTools)
            }
            .keyboardShortcut("k", modifiers: [.command, .option])

            Divider()

            // Opening either starts it; closing it ends the process.
            Button("Toggle superfile") {
                WorkspaceStore.shared.togglePanel(.superfile)
            }
            .keyboardShortcut("s", modifiers: [.command, .option])

            Button("Toggle btop") {
                WorkspaceStore.shared.togglePanel(.btop)
            }
            .keyboardShortcut("p", modifiers: [.command, .option])

            // The same two across the whole content area: the panels menu's
            // "full view". Shift is the only difference from the toggles above.
            Button("superfile in Full View") {
                WorkspaceStore.shared.openPanelExpanded(.superfile)
            }
            .keyboardShortcut("s", modifiers: [.command, .option, .shift])

            Button("btop in Full View") {
                WorkspaceStore.shared.openPanelExpanded(.btop)
            }
            .keyboardShortcut("p", modifiers: [.command, .option, .shift])

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

            // About what the composer's terminal last printed. Both ask first
            // when output sharing is off, and neither runs anything.
            Button("Explain Last Output") {
                WorkspaceStore.shared.requestComposerHelp(.explain)
            }
            .keyboardShortcut("e", modifiers: [.command, .option])

            Button("Suggest a Fix") {
                WorkspaceStore.shared.requestComposerHelp(.fix)
            }
            .keyboardShortcut("x", modifiers: [.command, .option])

            Divider()

            Button("Task Manager") {
                WorkspaceStore.shared.togglePanel(.tasks)
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
        }
    }
}
