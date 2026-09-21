import Foundation

/// Discrete attention request from a terminal pane — bell or an OSC
/// notification — as distinct from the cheap/frequent `onActivity` repaint
/// signal that feeds `session.activity`.
enum TerminalAttention: Equatable {
    case bell
    case osc9(message: String)
    case osc777(title: String?, body: String?)

    var kindName: String {
        switch self {
        case .bell: return "bell"
        case .osc9: return "osc9"
        case .osc777: return "osc777"
        }
    }

    var title: String? {
        switch self {
        case .bell: return nil
        case .osc9(let message): return message.isEmpty ? nil : message
        case .osc777(let title, _): return title
        }
    }

    var body: String? {
        switch self {
        case .bell, .osc9: return nil
        case .osc777(_, let body): return body
        }
    }
}
