import CRubberBand
import Foundation

/// Real-time Rubber Band stretcher over a decoded source, readable from any position.
/// Not thread-safe: one owner renders it sequentially.
final class StretchedSource {
    let source: PCMBuffer
    private let state: RubberBandState
    private var readFrame = 0
    private var pendingDiscard = 0
    private var scratch: [UnsafeMutablePointer<Float>] = []
    private var scratchCapacity = 0

    /// `ratio` is output duration / input duration (below 1 speeds the track up).
    init(source: PCMBuffer, ratio: Double) {
        self.source = source
        let options = RubberBandOptionProcessRealTime.rawValue
            | RubberBandOptionEngineFiner.rawValue
            | RubberBandOptionChannelsTogether.rawValue
        guard let state = rubberband_new(UInt32(source.sampleRate), UInt32(source.channels.count), Int32(bitPattern: options), ratio, 1) else {
            preconditionFailure("rubberband_new failed")
        }
        self.state = state
    }

    deinit {
        rubberband_delete(state)
        scratch.forEach { $0.deallocate() }
    }

    /// Restarts output so that its first frame corresponds to `frame` of the source
    /// (frames outside the source are silence).
    func seek(toSourceFrame frame: Int) {
        rubberband_reset(state)
        readFrame = frame - Int(rubberband_get_preferred_start_pad(state))
        pendingDiscard = Int(rubberband_get_start_delay(state))
    }

    /// Fills `output[channel][0..<frames]` with the next stretched frames.
    func render(into output: [UnsafeMutablePointer<Float>], frames: Int) {
        precondition(output.count == source.channels.count, "Channel count mismatch")
        var written = 0
        while written < frames {
            let available = Int(rubberband_available(state))
            guard available > 0 else {
                feed(max(Int(rubberband_get_samples_required(state)), 256))
                continue
            }
            if pendingDiscard > 0 {
                let count = min(available, pendingDiscard)
                ensureScratch(count)
                pendingDiscard -= retrieve(into: scratch, count: count)
            } else {
                written += retrieve(into: output.map { $0 + written }, count: min(available, frames - written))
            }
        }
    }

    private func retrieve(into pointers: [UnsafeMutablePointer<Float>], count: Int) -> Int {
        var optionals = pointers.map { Optional($0) }
        return optionals.withUnsafeMutableBufferPointer { Int(rubberband_retrieve(state, $0.baseAddress, UInt32(count))) }
    }

    /// Feeds `count` source frames from the read position.
    private func feed(_ count: Int) {
        ensureScratch(count)
        for (c, buffer) in scratch.enumerated() {
            source.copy(channel: c, from: readFrame, count: count, into: buffer)
        }
        var inputs = scratch.map { Optional(UnsafePointer($0)) }
        inputs.withUnsafeMutableBufferPointer { rubberband_process(state, $0.baseAddress, UInt32(count), 0) }
        readFrame += count
    }

    private func ensureScratch(_ count: Int) {
        guard count > scratchCapacity else { return }
        scratch.forEach { $0.deallocate() }
        scratch = source.channels.map { _ in UnsafeMutablePointer<Float>.allocate(capacity: count) }
        scratchCapacity = count
    }
}

/// Deinterleaved decoded audio.
public struct PCMBuffer: Sendable {
    public let channels: [[Float]]
    public let sampleRate: Double

    public init(channels: [[Float]], sampleRate: Double) {
        precondition(!channels.isEmpty && channels.allSatisfy { $0.count == channels[0].count }, "Channels must be non-empty and equally long")
        self.channels = channels
        self.sampleRate = sampleRate
    }

    public var frameCount: Int { channels[0].count }
    public var duration: TimeInterval { Double(frameCount) / sampleRate }

    /// Writes `count` frames starting at `start` into `destination`; frames outside the buffer are silence.
    func copy(channel: Int, from start: Int, count: Int, into destination: UnsafeMutablePointer<Float>) {
        destination.initialize(repeating: 0, count: count)
        let first = max(start, 0)
        let last = min(start + count, frameCount)
        guard last > first else { return }
        channels[channel].withUnsafeBufferPointer { samples in
            (destination + (first - start)).update(from: samples.baseAddress! + first, count: last - first)
        }
    }
}
