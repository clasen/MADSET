import Foundation

/// How a transition shapes the two tracks it joins: an equal-power fade on each side and a bass swap
/// (the incoming lows stay killed until the swap bar, the outgoing ones go after it).
public enum TransitionCurves {
    /// Part of an overlap the incoming track takes to fade in, and the outgoing one to fade out at the end.
    static let fadeFraction = 0.25
    /// Bars over which a bass swap ramps, to avoid a click.
    static let swapRampBars = 0.25

    /// Volume and low-band gain of `entry` at a set bar, from its own transition in and the next entry's.
    public static func levels(for entry: PlacedEntry, next: PlacedEntry?, atBar bar: Double) -> (volume: Float, low: Float) {
        let gains = gains(for: entry, next: next, atBar: bar)
        return (gains.volume, gains.low)
    }

    static func gains(for entry: PlacedEntry, next: PlacedEntry?, atBar bar: Double) -> MixGains {
        var gains = MixGains()
        if entry.overlapBars > 0, bar < Double(entry.startBar + entry.overlapBars) {
            let progress = (bar - Double(entry.startBar)) / Double(entry.overlapBars)
            gains.volume *= Float(sin(min(1, max(0, progress / fadeFraction)) * .pi / 2))
            gains.low *= ramp(bar, from: Double(entry.startBar + entry.bassSwapBar))
        }
        if let next, next.overlapBars > 0, bar >= Double(next.startBar) {
            let progress = (bar - Double(next.startBar)) / Double(next.overlapBars)
            gains.volume *= Float(cos(min(1, max(0, (progress - (1 - fadeFraction)) / fadeFraction)) * .pi / 2))
            gains.low *= 1 - ramp(bar, from: Double(next.startBar + next.bassSwapBar))
        }
        return gains
    }

    /// 0 before `start`, rising to 1 over the swap ramp.
    private static func ramp(_ bar: Double, from start: Double) -> Float {
        Float(min(1, max(0, (bar - start) / swapRampBars)))
    }
}
