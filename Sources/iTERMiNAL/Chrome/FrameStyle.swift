import Foundation

// The window frame's look, as plain values: what the Appearance settings
// choose between, and the arithmetic that turns a choice into a color. No
// SwiftUI here so it can be checked off a Mac (scripts/input-logic-check).

/// Where the frame's tint comes from.
///
/// A tint, not a replacement color: the frame is mixed a little of this into
/// the theme's own chrome color. The text and icons on it are chosen for the
/// theme's color, so letting someone pick a raw light color in dark mode would
/// put pale icons on a pale bar. A bounded mix keeps the frame recognisably
/// the theme's — near-black or near-white — however loud the tint is.
enum FrameTintSource: String, CaseIterable, Identifiable {
    case none, accent
    case blue, violet, green, orange, pink, teal, amber
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .accent: return "Accent"
        case .blue: return "Blue"
        case .violet: return "Violet"
        case .green: return "Green"
        case .orange: return "Orange"
        case .pink: return "Pink"
        case .teal: return "Teal"
        case .amber: return "Amber"
        case .custom: return "Custom"
        }
    }

    /// The color a named choice stands for. Nil for the three that are
    /// resolved elsewhere: none (no tint), accent (the user's accent) and
    /// custom (their own color).
    var presetHex: UInt32? {
        switch self {
        case .blue: return 0x3B82F6
        case .violet: return 0x8B5CF6
        case .green: return 0x10A37F
        case .orange: return 0xF97316
        case .pink: return 0xEC4899
        case .teal: return 0x14B8C6
        case .amber: return 0xD4A73C
        case .none, .accent, .custom: return nil
        }
    }
}

/// What the frame's typeface is. The interface only: the terminal has its own
/// font setting and is not affected.
enum FrameFontDesign: String, CaseIterable, Identifiable {
    case system, rounded, serif, monospaced

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .rounded: return "Rounded"
        case .serif: return "Serif"
        case .monospaced: return "Mono"
        }
    }
}

enum FrameStyle {
    // MARK: Ranges and defaults

    static let radiusRange: ClosedRange<Double> = 0...20
    static let gapRange: ClosedRange<Double> = 0...16
    /// The most of the tint that can be mixed in. Past about a third the
    /// frame stops looking like the theme and the text on it starts to lose
    /// contrast.
    static let strengthRange: ClosedRange<Double> = 0...0.35

    static let defaultRadius = 10.0
    static let defaultGap = 6.0
    static let defaultStrength = 0.12
    static let defaultCustomHex: UInt32 = 0x3B82F6

    static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        // NaN compares false against everything, so it would pass straight
        // through min/max and into a layout.
        guard value.isFinite else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    // MARK: Colour arithmetic

    /// `base` with `amount` of `tint` mixed in, per channel, on 0xRRGGBB.
    /// `amount` is clamped to the strength range, so a stored value that has
    /// gone bad cannot produce an unreadable frame.
    static func mix(base: UInt32, tint: UInt32, amount: Double) -> UInt32 {
        let t = clamp(amount, to: strengthRange)
        func channel(_ shift: UInt32) -> UInt32 {
            let b = Double((base >> shift) & 0xFF)
            let c = Double((tint >> shift) & 0xFF)
            let mixed = (b + (c - b) * t).rounded()
            return UInt32(min(max(mixed, 0), 255))
        }
        return (channel(16) << 16) | (channel(8) << 8) | channel(0)
    }

    /// The tint color for a choice, or nil when there is none.
    static func tintHex(source: FrameTintSource, accentHex: UInt32, customHex: UInt32) -> UInt32? {
        switch source {
        case .none: return nil
        case .accent: return accentHex
        case .custom: return customHex
        default: return source.presetHex
        }
    }

    /// The frame's color: the theme's chrome color with the tint mixed in.
    static func frameHex(
        base: UInt32,
        source: FrameTintSource,
        accentHex: UInt32,
        customHex: UInt32,
        strength: Double
    ) -> UInt32 {
        guard let tint = tintHex(source: source, accentHex: accentHex, customHex: customHex) else {
            return base
        }
        return mix(base: base, tint: tint, amount: strength)
    }

    // MARK: Hex text

    /// "#RRGGBB", for storing a color the user picked.
    static func hexString(_ hex: UInt32) -> String {
        let digits = String(hex & 0xFFFFFF, radix: 16, uppercase: true)
        return "#" + String(repeating: "0", count: 6 - digits.count) + digits
    }

    /// Reads "#RRGGBB", "RRGGBB" and the three-digit shorthand. Nil for
    /// anything else, so a corrupt stored value falls back to the default
    /// rather than becoming black.
    static func parseHex(_ text: String) -> UInt32? {
        var body = text.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("#") { body.removeFirst() }
        guard body.allSatisfy({ $0.isHexDigit }) else { return nil }
        if body.count == 3 {
            body = body.map { "\($0)\($0)" }.joined()
        }
        guard body.count == 6 else { return nil }
        return UInt32(body, radix: 16)
    }
}
