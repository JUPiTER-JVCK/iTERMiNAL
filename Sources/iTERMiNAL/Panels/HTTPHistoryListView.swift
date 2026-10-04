import SwiftUI

/// The sidebar's history list: every request sent from this pane, newest
/// first. A row loads its request back into the builder — load, don't run,
/// the same shape every suggestion surface in this app already follows; it
/// never sends anything on its own.
struct HTTPHistoryListView: View {
    @ObservedObject var model: HTTPClientModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var selection: UUID?

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        VStack(spacing: 0) {
            if model.history.isEmpty {
                VStack {
                    Spacer()
                    Text("No requests sent yet")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.history, selection: $selection) { entry in
                    HTTPHistoryRow(entry: entry, theme: theme)
                        .tag(entry.id)
                        .contentShape(Rectangle())
                        .gesture(TapGesture(count: 2).onEnded { model.loadFromHistory(entry) })
                        .simultaneousGesture(TapGesture().onEnded { selection = entry.id })
                        .contextMenu {
                            Button("Load") { model.loadFromHistory(entry) }
                        }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)

                FadedDivider()
                HStack {
                    Spacer()
                    Button("Clear History", role: .destructive, action: model.clearHistory)
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                        .padding(8)
                }
            }
        }
        .background(theme.background)
    }
}

private struct HTTPHistoryRow: View {
    let entry: HTTPHistoryEntry
    let theme: Theme

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.method)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 44, alignment: .leading)
            Text(entry.url)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(theme.textPrimary)
            Spacer(minLength: 8)
            statusBadge
        }
        .padding(.vertical, 1)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if let status = entry.statusCode {
            Text("\(status)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(status < 400 ? Color.green : Color.red)
        } else if entry.errorDescription != nil {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
        }
    }
}
