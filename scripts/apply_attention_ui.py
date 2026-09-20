#!/usr/bin/env python3
from pathlib import Path

sb_path = Path("Sources/iTERMiNAL/Chrome/SidebarView.swift")
sb = sb_path.read_text(encoding="utf-8")

old1 = "workspace.tabs.contains { $0.id != store.selectedTabID && ($0.primarySession?.isRunning ?? false) }"
new1 = """workspace.tabs.contains {
                    $0.id != store.selectedTabID && (
                        ($0.primarySession?.isRunning ?? false)
                        || ($0.primarySession?.needsAttention ?? false)
                    )
                }"""
assert sb.count(old1) == 1, f"sb old1 count={sb.count(old1)}"
sb = sb.replace(old1, new1, 1)

old2 = """    /// Blue dot = a live process in a tab you're not currently looking at.
    private var showsActivityDot: Bool {
        session.isRunning && store.selectedTabID != tab.id
    }"""
new2 = """    /// Blue dot = a live process in a tab you're not currently looking at.
    private var showsActivityDot: Bool {
        if session.needsAttention { return true }
        return session.isRunning && store.selectedTabID != tab.id
    }"""
assert sb.count(old2) == 1, f"sb old2 count={sb.count(old2)}"
sb = sb.replace(old2, new2, 1)
sb_path.write_text(sb, encoding="utf-8")

st_path = Path("Sources/iTERMiNAL/Settings/SettingsViews.swift")
st = st_path.read_text(encoding="utf-8")

old3 = """struct TerminalSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    private static let monospacedFamilies:"""
new3 = """struct TerminalSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var attention = AttentionSettings.shared

    private static let monospacedFamilies:"""
assert st.count(old3) == 1, f"st old3 count={st.count(old3)}"
st = st.replace(old3, new3, 1)

perf = '            Section("Performance") {'
idx_term = st.find("struct TerminalSettingsView")
idx_perf = st.find(perf, idx_term)
assert idx_perf != -1, "Performance section not found"
assert 'Section("Notifications")' not in st[idx_term:idx_perf]
notif = """            Section("Notifications") {
                Picker("Pane attention", selection: $attention.mode) {
                    ForEach(AttentionSettings.Mode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Text("Bell and OSC 9/777 from background panes show an in-app mark. System banners are optional and only fire when the app is inactive or the pane is unfocused.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
"""
st = st[:idx_perf] + notif + st[idx_perf:]

old4 = """            Section("Reset") {
                Button("Reset All Settings", role: .destructive) {
                    settings.resetToDefaults()
                }
            }"""
new4 = """            Section("Reset") {
                Button("Reset All Settings", role: .destructive) {
                    settings.resetToDefaults()
                    AttentionSettings.shared.resetToInApp()
                }
            }"""
assert st.count(old4) == 1, f"st old4 count={st.count(old4)}"
st = st.replace(old4, new4, 1)
st_path.write_text(st, encoding="utf-8")
print("patched ok")
