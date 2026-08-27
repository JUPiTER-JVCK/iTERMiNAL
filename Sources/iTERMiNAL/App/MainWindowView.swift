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
            if let tab = store.selectedTab {
                TabContentView(tab: tab)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                if settings.composerEnabled {
                    ComposerBar()
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 12)
                }
            } else {
                EmptyStateView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }
}

private struct TabContentView: View {
    @ObservedObject var tab: WorkspaceTab

    var body: some View {
        PaneTreeView(node: tab.root)
    }
}

/// Shown when no tab exists — a centered prompt in the spirit of an empty
/// chat: big question, one obvious action.
struct EmptyStateView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "terminal")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(theme.textSecondary)
            Text("What are we running today?")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Text("Start a terminal to get going.")
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
            Button {
                store.newTab()
            } label: {
                Label("New terminal", systemImage: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(settings.accentColor))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity)
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
