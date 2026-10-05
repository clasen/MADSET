import Foundation

/// Where a player starts so it comes in on the beat of another one that is playing: at the same place
/// in the bar, so both play their downbeats together. Beats are counted on the set's axis, where
/// every bar starts on a multiple of `beatsPerBar`.
public enum PhaseAlignment {
    public static let beatsPerBar = 4.0

    /// `time` moved ahead by less than a bar, to where it falls in the bar as `referenceBeat` does.
    public static func start(_ time: TimeInterval, beatDuration: TimeInterval, inPhaseWith referenceBeat: Double) -> TimeInterval {
        time + positiveRemainder(referenceBeat - time / beatDuration) * beatDuration
    }

    /// Frame of a buffer of `frames`, which the reference starts at `referenceBeat`, where set beat
    /// `startBeat` falls in phase with it. Negative when that frame went by at most a buffer ago, so the
    /// start is late by that many frames; nil when it comes after this buffer.
    public static func offset(startBeat: Double, referenceBeat: Double, framesPerBeat: Double, frames: Int) -> Int? {
        let ahead = positiveRemainder(startBeat - referenceBeat) * framesPerBeat
        if Int(ahead.rounded()) < frames { return Int(ahead.rounded()) }
        let late = beatsPerBar * framesPerBeat - ahead
        return late <= Double(frames) ? -Int(late.rounded()) : nil
    }

    private static func positiveRemainder(_ beats: Double) -> Double {
        let remainder = beats.truncatingRemainder(dividingBy: beatsPerBar)
        return remainder < 0 ? remainder + beatsPerBar : remainder
    }
}
