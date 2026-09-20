import Foundation
import Combine

/// Clears `needsAttention` when the focused session or selected tab changes.
///
/// Kept as a small Combine observer so focus-clear does not require rewriting
/// the large WorkspaceStore file in one MCP push.
@MainActor
final class AttentionFocusBinder {
    static let shared = AttentionFocusBinder()

    private var cancellables = Set<AnyCancellable>()

    private init() {}

    func start() {
        guard cancellables.isEmpty else { return }
        let store = WorkspaceStore.shared
        store.$focusedSessionID
            .receive(on: RunLoop.main)
            .sink { [weak store] id in
                guard let store, let id, let session = store.session(withID: id) else { return }
                session.clearAttention()
            }
            .store(in: &cancellables)
        store.$selectedTabID
            .receive(on: RunLoop.main)
            .sink { [weak store] _ in
                guard let store else { return }
                let sessions = store.selectedTab?.root.allSessions() ?? []
                if let id = store.focusedSessionID,
                   let session = sessions.first(where: { $0.id == id }) {
                    session.clearAttention()
                } else {
                    sessions.first?.clearAttention()
                }
            }
            .store(in: &cancellables)
    }
}
