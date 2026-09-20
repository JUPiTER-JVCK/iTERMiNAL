import Foundation
import Combine

/// Attention notification preferences, kept out of the large AppSettings
/// file so MCP can upload them cleanly. Default is in-app only.
final class AttentionSettings: ObservableObject {
    static let shared = AttentionSettings()

    enum Mode: String, CaseIterable, Identifiable {
        case off, inApp, inAppAndSystem
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: return "Off"
            case .inApp: return "In-app only"
            case .inAppAndSystem: return "In-app + system"
            }
        }
    }

    @Published var mode: Mode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "attentionMode")
            if mode == .inAppAndSystem {
                AttentionNotifier.shared.requestAuthorizationIfNeeded()
            }
        }
    }

    private init() {
        mode = Mode(rawValue: UserDefaults.standard.string(forKey: "attentionMode") ?? "") ?? .inApp
    }

    func resetToInApp() {
        mode = .inApp
    }
}
