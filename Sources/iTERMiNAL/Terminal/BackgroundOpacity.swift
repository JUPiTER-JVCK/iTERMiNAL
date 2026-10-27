import Foundation

/// How see-through a terminal's background may be, and the one decision that
/// goes with it: which frosted backdrop to put behind it.
///
/// Foundation only, so the rules are checked off a Mac like the rest of the
/// pure logic. What they are applied to — SwiftTerm's `backgroundOpacity` and
/// an `NSVisualEffectView` under the terminal — is in `SwiftTermEngine` and
/// `TerminalContainerView`.
enum BackgroundOpacity {
    /// The slider's range. Text stays solid at any value; below this most of
    /// what a terminal shows is the backdrop, which is no longer a terminal.
    static let range: ClosedRange<Double> = 0.2...1.0

    /// `value` brought into `range`. Something that is not a number — a saved
    /// preference that was damaged, a restored backup from elsewhere — reads as
    /// fully opaque, the setting's default, rather than as invisible.
    static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// Whether anything behind the terminal shows at this value. At 100% the
    /// backdrop is not built at all: a blurred view under a terminal that
    /// covers it would cost the GPU for nothing.
    static func isTranslucent(_ value: Double) -> Bool {
        clamped(value) < 1
    }

    /// The slider's reading: whole percent.
    static func percentText(_ value: Double) -> String {
        "\(Int((clamped(value) * 100).rounded()))%"
    }

    /// True when a terminal painted in `background` (0xRRGGBB) wants the dark
    /// frost behind it. A light frost under a dark tint turns it grey, and a
    /// dark one under a light tint does the same the other way, so the backdrop
    /// follows the terminal's colour and not the app's appearance — a light
    /// terminal theme in a dark app is an ordinary combination.
    static func prefersDarkBackdrop(background: UInt32) -> Bool {
        ColorMath.contrast(background, 0xFFFFFF) > ColorMath.contrast(background, 0x000000)
    }
}
