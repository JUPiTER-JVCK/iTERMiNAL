import Foundation

/// A rhythm for the cursor that SwiftTerm's plain blink is not: how its opacity
/// rises and falls over one loop. Foundation only, so the shapes are checked off
/// a Mac; `CursorAnimator` turns one into a Core Animation keyframe animation.
///
/// Each loop is a table written out, not generated from a random source: the
/// cursor looks the same every launch, and a check can read a table.
enum CursorAnimation: String, CaseIterable, Identifiable, Codable {
    /// The cursor does what its style says: steady, or SwiftTerm's own blink.
    case none
    /// A slow, smooth fade out and back.
    case breathing
    /// Two quick beats and a rest.
    case heartbeat
    /// A tube light that is nearly always on and now and then stutters.
    case neonFlicker
    /// A sharp flash that fades away.
    case pulse
    /// A flame: uneven, never quite out.
    case candle

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .breathing: return "Breathing"
        case .heartbeat: return "Heartbeat"
        case .neonFlicker: return "Neon flicker"
        case .pulse: return "Pulse"
        case .candle: return "Candle"
        }
    }

    /// One pass of the cursor's opacity. `values[i]` is the opacity at
    /// `times[i]`, a fraction of `duration` — and each is eased into the next in
    /// a straight line.
    struct Loop: Equatable {
        var duration: Double
        var times: [Double]
        var values: [Double]
    }

    /// Nil for `.none`, which has no loop of its own.
    var loop: Loop? {
        switch self {
        case .none:
            return nil
        case .breathing:
            // A cosine, sampled often enough to look smooth under straight
            // lines: full at the start, lowest halfway, full again.
            let samples = 24
            let low = 0.12
            let times = (0...samples).map { Double($0) / Double(samples) }
            let values = times.map { low + (1 - low) * (0.5 + 0.5 * cos(2 * Double.pi * $0)) }
            return Loop(duration: 3.2, times: times, values: values)
        case .heartbeat:
            return Loop(
                duration: 1.5,
                times:  [0.00, 0.08, 0.16, 0.26, 0.40, 1.00],
                values: [0.30, 1.00, 0.45, 0.95, 0.30, 0.30]
            )
        case .neonFlicker:
            return Loop(
                duration: 4.0,
                times:  [0.00, 0.30, 0.31, 0.34, 0.35, 0.37, 0.62, 0.63, 0.64, 0.66, 0.69, 0.72, 0.74, 0.95, 0.96, 0.98, 1.00],
                values: [1.00, 1.00, 0.25, 1.00, 0.45, 1.00, 1.00, 0.15, 1.00, 0.30, 1.00, 0.55, 1.00, 1.00, 0.20, 1.00, 1.00]
            )
        case .pulse:
            return Loop(
                duration: 1.2,
                times:  [0.00, 0.05, 0.30, 0.60, 1.00],
                values: [0.15, 1.00, 0.55, 0.25, 0.15]
            )
        case .candle:
            return Loop(
                duration: 6.0,
                times:  [0.00, 0.07, 0.15, 0.22, 0.31, 0.38, 0.47, 0.55, 0.63, 0.71, 0.79, 0.88, 1.00],
                values: [0.90, 1.00, 0.78, 0.95, 0.70, 0.92, 0.82, 1.00, 0.72, 0.94, 0.80, 0.97, 0.90]
            )
        }
    }
}
