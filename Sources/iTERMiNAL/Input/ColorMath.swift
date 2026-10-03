import Foundation

/// Colour arithmetic on `0xRRGGBB` values.
///
/// No AppKit, so the logic that depends on it can be compiled and tested
/// without a Mac. `ToolTheming` had these as private conveniences; they live
/// here now so the composer's syntax colours and the tools' themes cannot
/// disagree about what "faded toward the background" means.
enum ColorMath {
    /// `a` moved `amount` of the way to `b`, per channel.
    static func mix(_ a: UInt32, _ b: UInt32, _ amount: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let from = Double((a >> shift) & 0xFF)
            let to = Double((b >> shift) & 0xFF)
            return UInt32((from + (to - from) * amount).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }

    static func hex(_ color: UInt32) -> String {
        String(format: "#%06x", color & 0xFFFFFF)
    }

    /// WCAG contrast ratio between two colours, 1 (none) to 21.
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func luminance(_ color: UInt32) -> Double {
            func linear(_ shift: UInt32) -> Double {
                let c = Double((color >> shift) & 0xFF) / 255
                return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(16) + 0.7152 * linear(8) + 0.0722 * linear(0)
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}
