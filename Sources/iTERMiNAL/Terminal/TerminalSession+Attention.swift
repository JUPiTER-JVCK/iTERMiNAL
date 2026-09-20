import Foundation

extension TerminalSession {
    /// Marks this session as needing attention and publishes `session.attention`.
    ///
    /// Rapid repeats within ~1s are coalesced: identical OSC text refreshes
    /// the timestamp without stacking another event; a fresh kind/text still
    /// waits for the debounce window so a ringing bell cannot flood the bus.
    func noteAttention(_ attention: TerminalAttention) {
        let mode = AppSettings.shared.attentionMode
        let focused = WorkspaceStore.shared.focusedSessionID == id
        let fingerprint = attentionFingerprint(attention)
        let now = Date()
        let withinWindow = now.timeIntervalSince(lastAttentionAt) < 1.0
        if withinWindow, lastAttentionFingerprint == fingerprint {
            lastAttentionAt = now
            lastAttention = attention
            return
        }
        if withinWindow {
            return
        }
        lastAttentionAt = now
        lastAttentionFingerprint = fingerprint
        lastAttention = attention

        if mode != .off, !focused {
            needsAttention = true
        }

        var data: [String: Any] = [
            "session": id.uuidString,
            "kind": attention.kindName,
            "focused": focused,
        ]
        if let title = attention.title { data["title"] = title }
        if let body = attention.body { data["body"] = body }
        EventBus.shared.publish(APIEvent("session.attention", data))

        AttentionNotifier.shared.maybeNotify(attention, session: self, sessionFocused: focused)
    }

    private func attentionFingerprint(_ attention: TerminalAttention) -> String {
        switch attention {
        case .bell:
            return "bell"
        case .osc9(let message):
            return "osc9:" + message
        case .osc777(let title, let body):
            return "osc777:" + (title ?? "") + "|" + (body ?? "")
        }
    }
}
