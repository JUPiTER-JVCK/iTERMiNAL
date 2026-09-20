import AppKit
import UserNotifications

/// Posts macOS system notifications for pane attention when the user has
/// opted in. In-app indicators live on `TerminalSession.needsAttention`;
/// this type only covers the optional system banner path.
final class AttentionNotifier {
    static let shared = AttentionNotifier()

    private static let maxTextLength = 200
    private let center = UNUserNotificationCenter.current()

    private init() {}

    /// Asks for notification permission when the user turns on system mode.
    func requestAuthorizationIfNeeded() {
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                self.center.requestAuthorization(options: [.alert, .sound]) { _, error in
                    if let error {
                        NSLog("Attention notification authorization failed: \(error.localizedDescription)")
                    }
                }
            default:
                break
            }
        }
    }

    /// Posts a system notification when mode allows and the pane is not
    /// already in front of the user (app inactive, or this session unfocused).
    func maybeNotify(
        _ attention: TerminalAttention,
        session: TerminalSession,
        sessionFocused: Bool
    ) {
        let mode = AppSettings.shared.attentionMode
        guard mode == .inAppAndSystem else { return }

        let appActive = NSApp?.isActive ?? false
        guard !appActive || !sessionFocused else { return }

        let content = UNMutableNotificationContent()
        content.title = Self.truncate(Self.notificationTitle(attention, session: session))
        if let body = Self.notificationBody(attention) {
            content.body = Self.truncate(body)
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "attention-\(session.id.uuidString)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                NSLog("Attention notification failed: \(error.localizedDescription)")
            }
        }
    }

    private static func notificationTitle(
        _ attention: TerminalAttention,
        session: TerminalSession
    ) -> String {
        switch attention {
        case .bell:
            return session.displayTitle
        case .osc9(let message):
            return message.isEmpty ? session.displayTitle : message
        case .osc777(let title, _):
            if let title, !title.isEmpty { return title }
            return session.displayTitle
        }
    }

    private static func notificationBody(_ attention: TerminalAttention) -> String? {
        switch attention {
        case .bell:
            return "Terminal bell"
        case .osc9:
            return nil
        case .osc777(_, let body):
            guard let body, !body.isEmpty else { return nil }
            return body
        }
    }

    private static func truncate(_ text: String) -> String {
        guard text.count > maxTextLength else { return text }
        return String(text.prefix(maxTextLength - 1)) + "…"
    }
}
