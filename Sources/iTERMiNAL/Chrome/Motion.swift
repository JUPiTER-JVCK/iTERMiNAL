import SwiftUI
import AppKit

/// Every animation curve in one place, so the feel can be retuned against
/// reference video without hunting through views.
///
/// Reduce Motion is honoured here, once, rather than in every view. With the
/// system setting on, two things change, and they are different mechanisms: a
/// spring becomes a short ease, so nothing overshoots or bounces, and a
/// transition that slides becomes a plain fade. A timing curve cannot take the
/// movement out by itself; the transitions are what do that.
///
/// The two are read differently, on purpose. A curve is read when it is asked
/// for, which is when an animation starts, so it is always current. A
/// transition is different: a view leaves with the transition it last rendered
/// with, and SwiftUI cannot see this file read the system setting, so nothing
/// would re-render a panel that is already open when the setting changes. Its
/// transitions therefore take the value from the view's own
/// `accessibilityReduceMotion` environment, which SwiftUI does refresh.
enum Motion {
    /// Whether the person asked the system to cut down on movement.
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// What each spring below becomes under Reduce Motion: a quick, settled
    /// ease with no overshoot. Whether anything still travels is decided by the
    /// transitions further down, not by this curve.
    private static let shortEase = Animation.easeOut(duration: 0.12)

    /// Side panels sliding in from the trailing edge.
    static var panel: Animation {
        reduceMotion ? shortEase : .spring(response: 0.32, dampingFraction: 0.86)
    }
    /// Sidebar section disclosure.
    static var disclosure: Animation {
        reduceMotion ? shortEase : .spring(response: 0.22, dampingFraction: 0.9)
    }
    /// Command palette appear/dismiss.
    static let palette = Animation.easeOut(duration: 0.16)
    /// Status and notice banners.
    static var banner: Animation {
        reduceMotion ? shortEase : .spring(response: 0.28, dampingFraction: 0.88)
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

    /// Pass the view's `@Environment(\.accessibilityReduceMotion)`, not
    /// `Motion.reduceMotion`; see the note above.
    static func panelTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity)
    }

    /// The terminal dock rising from the bottom edge.
    static func dockTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }

    static func bannerTransition(reduceMotion: Bool) -> AnyTransition {
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
