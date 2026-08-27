import SwiftUI

/// Every animation curve in one place, so the feel can be retuned against
/// reference video without hunting through views.
enum Motion {
    /// Side panels sliding in from the trailing edge.
    static let panel = Animation.spring(response: 0.32, dampingFraction: 0.86)
    /// Sidebar section disclosure.
    static let disclosure = Animation.spring(response: 0.22, dampingFraction: 0.9)
    /// Command palette appear/dismiss.
    static let palette = Animation.easeOut(duration: 0.16)
    /// Status and notice banners.
    static let banner = Animation.spring(response: 0.28, dampingFraction: 0.88)

    static let panelTransition = AnyTransition.move(edge: .trailing)
        .combined(with: .opacity)

    static let bannerTransition = AnyTransition.move(edge: .top)
        .combined(with: .opacity)
}

/// Compact relative time for sidebar rows: "now", "5m", "2h", "3d", "2w".
enum RelativeTime {
    static func short(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        case ..<604_800: return "\(Int(seconds / 86_400))d"
        case ..<2_629_746: return "\(Int(seconds / 604_800))w"
        default: return "\(Int(seconds / 2_629_746))mo"
        }
    }
}
