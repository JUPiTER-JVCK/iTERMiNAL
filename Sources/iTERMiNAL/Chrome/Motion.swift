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
    /// How much faster than designed every animation runs (Settings →
    /// Appearance → Effects). Set by `AppSettings`; 1 leaves them as drawn.
    static var speed: Double = 1

    private static func paced(_ animation: Animation) -> Animation {
        speed == 1 ? animation : animation.speed(speed)
    }

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
        paced(reduceMotion ? shortEase : .spring(response: 0.32, dampingFraction: 0.86))
    }
    /// Sidebar section disclosure.
    static var disclosure: Animation {
        paced(reduceMotion ? shortEase : .spring(response: 0.22, dampingFraction: 0.9))
    }
    /// Command palette appear/dismiss.
    static var palette: Animation { paced(.easeOut(duration: 0.16)) }
    /// Status and notice banners.
    static var banner: Animation {
        paced(reduceMotion ? shortEase : .spring(response: 0.28, dampingFraction: 0.88))
    }

    /// The composer's input field warming on focus.
    static var field: Animation { paced(.easeOut(duration: 0.18)) }
    /// A control giving under the pointer: quick, with a little give.
    static var press: Animation { paced(.spring(response: 0.22, dampingFraction: 0.68)) }

    /// A row's background warming when the pointer arrives or the row is
    /// selected, and the controls that appear on it. A colour change, not
    /// movement, so Reduce Motion leaves it as it is: it is only quick enough
    /// to stop the change reading as a flash.
    static var hover: Animation { paced(.easeOut(duration: 0.14)) }

    /// The composer's suggestion list opening, and its highlight moving between
    /// rows. A little give, but settled quickly: it is in the way of typing.
    static var suggestion: Animation { paced(.spring(response: 0.24, dampingFraction: 0.86)) }

    /// Moving between the pages the rail opens — the terminal, Tasks, the
    /// cheatsheet. Critically damped: a page settling into place should not
    /// bounce.
    static var page: Animation {
        paced(reduceMotion ? shortEase : .spring(response: 0.3, dampingFraction: 1))
    }

    /// The composer folding to its pill and opening out again.
    static var morph: Animation {
        paced(reduceMotion ? shortEase : .spring(response: 0.34, dampingFraction: 0.84))
    }

    /// Pass the view's `@Environment(\.accessibilityReduceMotion)`, not
    /// `Motion.reduceMotion`; see the note above.
    static func panelTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity)
    }

    /// The workspaces panel sliding in from the rail.
    static func railPanelTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity)
    }

    /// The terminal dock rising from the bottom edge.
    static func dockTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }

    static func bannerTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }

    /// A page arriving: it fades in while settling the last few points down
    /// into place; the page it replaces simply fades. A short drift rather
    /// than a full slide — the whole surface travelling across the window is
    /// a lot of movement for changing what it shows. Downward, from under
    /// the card's top edge, which clips it: drifting up from below would pass
    /// over the dock and the status strip on the way.
    static func pageTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .opacity.combined(with: .offset(y: -8)),
                removal: .opacity
            )
    }

    /// A floating surface growing out of, or shrinking back into, the edge
    /// it is anchored to — the composer's card and its pill. The scale is
    /// slight: enough to read as the same object changing shape, not a zoom.
    static func morphTransition(reduceMotion: Bool, anchor: UnitPoint = .bottom) -> AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.94, anchor: anchor).combined(with: .opacity)
    }
}

extension View {
    /// A symbol giving a small bounce when `value` changes — a pin taking, a
    /// toggle flipping. Left out altogether under Reduce Motion: pass the
    /// view's `accessibilityReduceMotion`, as for the transitions above.
    @ViewBuilder
    func symbolBounce<Value: Equatable>(on value: Value, reduceMotion: Bool) -> some View {
        if reduceMotion {
            self
        } else {
            self.symbolEffect(.bounce, value: value)
        }
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
