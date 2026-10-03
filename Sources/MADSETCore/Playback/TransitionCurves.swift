import Foundation

/// How a transition shapes the two tracks it joins: an equal-power fade on each side (the incoming
/// track's at the start of the overlap, the outgoing one's at its end) and a bass swap (the incoming
/// lows stay killed until the swap bar, the outgoing ones go after it).
public enum TransitionCurves {
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
            let progress = fadeProgress(bar, from: Double(entry.startBar), over: entry.fadeInBars)
            gains.volume *= Float(sin(progress * .pi / 2))
            gains.low *= ramp(bar, from: Double(entry.startBar + entry.bassSwapBar))
        }
        if let next, next.overlapBars > 0, bar >= Double(next.startBar) {
            let progress = fadeProgress(bar, from: Double(next.startBar + next.overlapBars - next.fadeOutBars), over: next.fadeOutBars)
            gains.volume *= Float(cos(progress * .pi / 2))
            gains.low *= 1 - ramp(bar, from: Double(next.startBar + next.bassSwapBar))
        }
        return gains
    }

    /// 0 before `start`, rising to 1 over `bars`; a fade of no bars is a cut at `start`.
    private static func fadeProgress(_ bar: Double, from start: Double, over bars: Int) -> Double {
        guard bars > 0 else { return bar >= start ? 1 : 0 }
        return min(1, max(0, (bar - start) / Double(bars)))
    }

    /// 0 before `start`, rising to 1 over the swap ramp.
    private static func ramp(_ bar: Double, from start: Double) -> Float {
        Float(min(1, max(0, (bar - start) / swapRampBars)))
    }
}
