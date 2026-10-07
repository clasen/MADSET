import Foundation
import Synchronization

/// What a player plays, as it is heard: its audio, counted in frames since the player was made, and
/// the host time one of those frames is heard at. Another player's audio callback mixes it in, lined
/// up on the time both are heard, for a cue mix. The player's producer writes the audio and its audio
/// callback the timing; the reader takes both without locking.
public final class HeardAudio: @unchecked Sendable {
    /// Seconds of audio kept after it was written, for a reader that hears it later than the writer.
    static let historySeconds = 1.0
    /// Frames a reader lets its device's clock drift from the writer's before it catches up with a fade.
    static let driftFrames = 64

    private let sampleRate: Double
    private let capacity: Int
    /// Frames the writer may be writing past the last count it published.
    private let writeAhead: Int
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let written = Atomic<Int>(0)
    /// Frame count heard at a host time (seconds, as bits); a zero time while nothing is heard.
    private let anchor = Atomic<WordPair>(WordPair(first: 0, second: 0))

    init(sampleRate: Double, writeAhead: Int) {
        self.sampleRate = sampleRate
        self.writeAhead = writeAhead
        capacity = writeAhead + Int(Self.historySeconds * sampleRate)
        left = .allocate(capacity: capacity)
        right = .allocate(capacity: capacity)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    /// Frames written so far.
    var count: Int { written.load(ordering: .acquiring) }

    /// Writer's producer.
    func write(left source: UnsafePointer<Float>, right sourceRight: UnsafePointer<Float>, frames: Int) {
        let start = written.load(ordering: .relaxed)
        for i in 0..<frames {
            let index = (start + i) % capacity
            left[index] = source[i]
            right[index] = sourceRight[i]
        }
        written.store(start + frames, ordering: .releasing)
    }

    /// Writer's audio callback: frame `frame` is heard at `hostTime` seconds.
    func publish(frame: Int, heardAt hostTime: Double) {
        anchor.store(WordPair(first: UInt(frame), second: UInt(hostTime.bitPattern)), ordering: .releasing)
    }

    /// Writer's audio callback: nothing is heard.
    func silence() {
        anchor.store(WordPair(first: 0, second: 0), ordering: .releasing)
    }

    /// Reader's audio callback: adds the `frames` heard from `hostTime` on into `left` and `right`,
    /// with the gain going from `gain.from` to `gain.to`. Carries on from `cursor`, the frame the last
    /// call read up to, unless the clocks drifted apart; then, or without a cursor, it finds its place
    /// and fades in. Returns the frame read up to, nil when nothing is heard.
    func mix(into left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, frames: Int, heardAt hostTime: Double,
             gain: (from: Float, to: Float), cursor: Int?) -> Int? {
        let anchor = anchor.load(ordering: .acquiring)
        guard anchor.second != 0 else { return nil }
        var start = Int(anchor.first) + Int(((hostTime - Double(bitPattern: UInt64(anchor.second))) * sampleRate).rounded())
        let continues = cursor.map { abs(start - $0) <= Self.driftFrames } ?? false
        if continues, let cursor { start = cursor }
        let end = written.load(ordering: .acquiring)
        guard start >= end + writeAhead - capacity, start + frames <= end else { return nil }
        let fade = continues ? 0 : min(SetRenderer.declickFrames, frames)
        for i in 0..<frames {
            var g = gain.from + (gain.to - gain.from) * Float(i) / Float(frames)
            if i < fade { g *= Float(i) / Float(fade) }
            let index = (start + i) % capacity
            left[i] += self.left[index] * g
            right[i] += self.right[index] * g
        }
        return start + frames
    }
}

/// Gains of the monitor's own audio and of the main output's in the headphones.
public enum CueMix {
    /// `level` and `mix` run from 0 to 1. A mix of 0 is the monitor alone and 1 the main output alone,
    /// at equal power in between; the level tapers like a fader, squared.
    public static func gains(level: Double, mix: Double) -> (own: Float, reference: Float) {
        let level = level * level
        let angle = mix * .pi / 2
        return (Float(level * cos(angle)), Float(level * sin(angle)))
    }
}
