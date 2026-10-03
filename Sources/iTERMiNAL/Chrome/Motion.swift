import SwiftUI
import AppKit

/// Every animation curve in one place, so the feel can be retuned against
/// reference video without hunting through views.
///
/// Reduce Motion is honoured here, once, rather than in every view: with the
/// system setting on, a curve that moves things becomes a short fade and a
/// transition that slides becomes a fade. The setting is read each time a curve
/// is asked for, so changing it in System Settings applies to the next
/// animation without a relaunch. Views that already check the environment
/// themselves (the composer) keep doing so; this does not replace that.
enum Motion {
    /// Whether the person asked the system to cut down on movement.
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// What every moving curve becomes under Reduce Motion: no travel, just a
    /// quick change of opacity.
    private static let fade = Animation.easeOut(duration: 0.12)

    /// Side panels sliding in from the trailing edge.
    static var panel: Animation {
        reduceMotion ? fade : .spring(response: 0.32, dampingFraction: 0.86)
    }
    /// Sidebar section disclosure.
    static var disclosure: Animation {
        reduceMotion ? fade : .spring(response: 0.22, dampingFraction: 0.9)
    }
    /// Command palette appear/dismiss.
    static let palette = Animation.easeOut(duration: 0.16)
    /// Status and notice banners.
    static var banner: Animation {
        reduceMotion ? fade : .spring(response: 0.28, dampingFraction: 0.88)
    }

    /// The composer's input field warming on focus.
    static let field = Animation.easeOut(duration: 0.18)
    /// A control giving under the pointer: quick, with a little give.
    static let press = Animation.spring(response: 0.22, dampingFraction: 0.68)

    /// A row's background warming when the pointer arrives or the row is
    /// selected, and the controls that appear on it. A colour change, not
    /// movement, so Reduce Motion leaves it as it is: it is only quick enough
    /// to stop the change reading as a flash.
    static let hover = Animation.easeOut(duration: 0.14)

    /// The composer's suggestion list opening, and its highlight moving between
    /// rows. A little give, but settled quickly: it is in the way of typing.
    static let suggestion = Animation.spring(response: 0.24, dampingFraction: 0.86)

    static var panelTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity)
    }

    /// The terminal dock rising from the bottom edge.
    static var dockTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }

    static var bannerTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }
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
