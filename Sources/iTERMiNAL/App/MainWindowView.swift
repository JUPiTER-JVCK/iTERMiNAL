import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            DetailView()
                .inspector(isPresented: inspectorBinding) {
                    InspectorPanelView()
                        .inspectorColumnWidth(min: 300, ideal: 400, max: 700)
                }
        }
        .frame(minWidth: 900, minHeight: 560)
        .sheet(isPresented: $store.showCommandPalette) {
            CommandPaletteView()
                .environmentObject(store)
                .environmentObject(settings)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ForEach(SidePanel.allCases) { panel in
                    Button {
                        store.togglePanel(panel)
                    } label: {
                        Image(systemName: panel.icon)
                    }
                    .help("Toggle \(panel.title) panel")
                }
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
            }
        }
    }

    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { store.activePanel != nil },
            set: { if !$0 { store.activePanel = nil } }
        )
    }
}

struct DetailView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        VStack(spacing: 0) {
            switch store.detailMode {
            case .automations:
                ModePlaceholderView(
                    icon: "clock",
                    title: "Automations",
                    caption: "Scheduled commands and triggers are coming soon."
                )
            case .skills:
                ModePlaceholderView(
                    icon: "book",
                    title: "Skills",
                    caption: "Reusable command snippets are coming soon."
                )
            case .terminal:
                if let tab = store.selectedTab {
                    TabHeaderView(tab: tab)
                    TabContentView(tab: tab)
                        .padding(.horizontal, 10)
                } else {
                    LandingView()
                }
                if settings.composerEnabled {
                    ComposerBar()
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }
}

private struct TabHeaderView: View {
    @ObservedObject var tab: WorkspaceTab
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        HStack {
            Text(tab.displayName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

private struct TabContentView: View {
    @ObservedObject var tab: WorkspaceTab

    var body: some View {
        PaneTreeView(node: tab.root)
    }
}

/// The "no tab open" landing: centered glyph, "Let's build", a workspace
/// picker pill, and a row of quick-start cards — mirroring the reference
/// app's new-thread screen.
private struct LandingView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: "apple.terminal")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(theme.textPrimary)

            Text("Let's build")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(theme.textPrimary)

            Menu {
                ForEach(store.workspaces) { workspace in
                    Button(workspace.name) { store.newTab(in: workspace) }
                }
                Divider()
                Button("New Workspace") { store.newWorkspace() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                    Text(store.currentWorkspace?.name ?? "Workspace")
                        .font(.system(size: 12, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(theme.surface))
                .overlay(Capsule().strokeBorder(theme.surfaceBorder))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            HStack(spacing: 12) {
                SuggestionCard(icon: "terminal", tint: settings.accentColor, title: "Open a new terminal") {
                    store.newTab()
                }
                SuggestionCard(icon: "rectangle.split.2x1", tint: Color(hex: 0x3B82F6), title: "Start with split panes") {
                    store.newTab()
                    store.splitFocusedPane(.horizontal, kind: .terminal)
                }
                SuggestionCard(icon: "globe", tint: Color(hex: 0x8B5CF6), title: "Browse the web") {
                    store.togglePanel(.browser)
                }
                SuggestionCard(icon: "folder", tint: Color(hex: 0xF97316), title: "Explore your files") {
                    store.togglePanel(.files)
                }
            }
            .padding(.top, 10)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SuggestionCard: View {
    let icon: String
    let tint: Color
    let title: String
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(width: 150, height: 88, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(hovering ? theme.surfaceHover : theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(theme.surfaceBorder)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Placeholder detail surface for the sidebar sections that ship later.
private struct ModePlaceholderView: View {
    let icon: String
    let title: String
    let caption: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(theme.textSecondary)
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Text(caption)
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Sliding right panel: a segmented switcher over the shared browser and
/// file models.
struct InspectorPanelView: View {
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        VStack(spacing: 0) {
            Picker("Panel", selection: panelSelection) {
                ForEach(SidePanel.allCases) { panel in
                    Text(panel.title).tag(panel)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            Divider()

            switch store.activePanel ?? .browser {
            case .browser:
                BrowserPaneView(model: store.panelBrowser)
            case .files:
                FilePaneView(model: store.panelFiles)
            }
        }
    }

    private var panelSelection: Binding<SidePanel> {
        Binding(
            get: { store.activePanel ?? .browser },
            set: { store.activePanel = $0 }
        )
    }
}
