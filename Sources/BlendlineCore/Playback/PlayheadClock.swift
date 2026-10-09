import CoreAudio
import Foundation
import Synchronization

/// Where the set's beats fall in host time while a player plays, for clocks that follow it (MIDI
/// clock out). The audio callback publishes it every buffer; any thread reads it without locking.
public final class PlayheadClock: Sendable {
    /// Set beat `beat` is heard at `hostTime` (seconds of host time), moving at `beatsPerSecond`.
    public struct Position: Sendable, Equatable {
        public var beat: Double
        public var hostTime: Double
        public var beatsPerSecond: Double

        public init(beat: Double, hostTime: Double, beatsPerSecond: Double) {
            self.beat = beat
            self.hostTime = hostTime
            self.beatsPerSecond = beatsPerSecond
        }
    }

    private let sampleRate: Double
    /// Host time (ticks) the anchor frame is heard at, and that frame in beats; zero ticks while stopped.
    private let anchor = Atomic<WordPair>(WordPair(first: 0, second: 0))
    /// Bit patterns of `Double`s, so the audio callback reads them without locking.
    private let framesPerBeat = Atomic<UInt64>(0)
    private let outputLatency = Atomic<UInt64>(0)

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    /// Where the set is heard now, or nil while the player is paused.
    public var position: Position? {
        let anchor = anchor.load(ordering: .acquiring)
        let framesPerBeat = Double(bitPattern: framesPerBeat.load(ordering: .acquiring))
        guard anchor.first != 0, framesPerBeat > 0 else { return nil }
        return Position(beat: Double(bitPattern: UInt64(anchor.second)), hostTime: HostTime.seconds(UInt64(anchor.first)),
                        beatsPerSecond: sampleRate / framesPerBeat)
    }

    /// The tempo of the audio that plays from now on: set by the producer while nothing is consumed, or
    /// by the audio callback where a tempo change is heard.
    func setFramesPerBeat(_ frames: Double) {
        framesPerBeat.store(frames.bitPattern, ordering: .releasing)
    }

    /// Seconds from the audio callback to the speakers.
    func setOutputLatency(_ seconds: TimeInterval) {
        outputLatency.store(seconds.bitPattern, ordering: .releasing)
    }

    /// Audio callback side: set frame `frame` starts the buffer rendered for `timestamp`.
    func publish(frame: Int, at timestamp: AudioTimeStamp) {
        let framesPerBeat = Double(bitPattern: framesPerBeat.load(ordering: .acquiring))
        guard let heard = heardTicks(of: timestamp), framesPerBeat > 0 else { return stop() }
        anchor.store(WordPair(first: UInt(heard), second: UInt((Double(frame) / framesPerBeat).bitPattern)), ordering: .releasing)
    }

    /// Audio callback side: host time, in seconds, the buffer rendered for `timestamp` is heard at.
    func heardTime(of timestamp: AudioTimeStamp) -> Double? {
        heardTicks(of: timestamp).map(HostTime.seconds)
    }

    private func heardTicks(of timestamp: AudioTimeStamp) -> UInt64? {
        guard timestamp.mFlags.contains(.hostTimeValid) else { return nil }
        return timestamp.mHostTime + HostTime.ticks(Double(bitPattern: outputLatency.load(ordering: .acquiring)))
    }

    func stop() {
        anchor.store(WordPair(first: 0, second: 0), ordering: .releasing)
    }
}

/// Mach host time, the timeline Core Audio and Core MIDI timestamps use.
public enum HostTime {
    public static var now: Double { seconds(AudioGetCurrentHostTime()) }

    public static func seconds(_ ticks: UInt64) -> Double { Double(AudioConvertHostTimeToNanos(ticks)) / 1e9 }

    public static func ticks(_ seconds: Double) -> UInt64 { AudioConvertNanosToHostTime(UInt64(max(0, seconds) * 1e9)) }
}
