@preconcurrency import AVFoundation
import Foundation
import Synchronization

/// Plays a `SetLayout`. A producer thread mixes ahead of the playhead into a ring buffer; the audio
/// callback only copies from it. Layout edits reach the producer without interrupting tracks whose
/// placement is unchanged; seeks and tempo changes flush the buffer.
public final class SetPlayer: @unchecked Sendable {
    private let config: AppConfig.Playback
    private let engine: AVAudioEngine
    private let shared: SharedState

    /// `engine` is injectable so tests can render without a sound device (manual rendering mode).
    public init(config: AppConfig.Playback, sources: SourceCache, engine: AVAudioEngine = AVAudioEngine()) throws {
        self.config = config
        self.engine = engine
        shared = SharedState(capacity: Int(config.bufferSeconds * config.sampleRate) + config.blockFrames)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: config.sampleRate, channels: 2) else {
            preconditionFailure("Unsupported playback format")
        }
        let shared = shared
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            let left = buffers[0].mData!.assumingMemoryBound(to: Float.self)
            let right = buffers[1].mData!.assumingMemoryBound(to: Float.self)
            shared.consume(left: left, right: right, frames: Int(frameCount))
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        try engine.start()

        // The thread holds only what it needs, so releasing the player stops it.
        let thread = Thread { Producer(shared: shared, config: config, sources: sources, engine: engine).run() }
        thread.qualityOfService = .userInteractive
        thread.name = "MADSET mixer"
        thread.start()
    }

    deinit {
        shared.running.store(false, ordering: .releasing)
        engine.stop()
    }

    public var isPlaying: Bool { shared.playing.load(ordering: .acquiring) }

    /// Seconds into the set at the playhead.
    public var currentTime: TimeInterval { Double(shared.playheadFrame) / config.sampleRate }

    public func play() { shared.playing.store(true, ordering: .releasing) }
    public func pause() { shared.playing.store(false, ordering: .releasing) }

    public func load(_ layout: SetLayout) { shared.commands.withLock { $0.append(.layout(layout)) } }
    public func seek(to time: TimeInterval) { shared.commands.withLock { $0.append(.seek(max(0, time))) } }
}

/// The mixing loop, run on its own thread.
private struct Producer {
    let shared: SharedState
    let config: AppConfig.Playback
    let sources: SourceCache
    let engine: AVAudioEngine

    func run() {
        var renderer: SetRenderer?
        let left = UnsafeMutablePointer<Float>.allocate(capacity: config.blockFrames)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: config.blockFrames)
        defer {
            left.deallocate()
            right.deallocate()
        }
        while shared.running.load(ordering: .acquiring) {
            for command in shared.commands.withLock({ pending in defer { pending.removeAll() }; return pending }) {
                switch command {
                case .layout(let layout):
                    guard let current = renderer else {
                        renderer = SetRenderer(layout: layout, sources: sources, config: config)
                        continue
                    }
                    if current.layout.bpm != layout.bpm {
                        let bar = Double(shared.playheadFrame) / current.framesPerBar
                        current.update(layout)
                        flush(renderer: current, toFrame: Int(bar * current.framesPerBar))
                    } else {
                        current.update(layout)
                    }
                case .seek(let time):
                    if let renderer { flush(renderer: renderer, toFrame: Int(time * config.sampleRate)) }
                }
            }
            guard let renderer, shared.freeFrames >= config.blockFrames else {
                Thread.sleep(forTimeInterval: 0.002)
                continue
            }
            renderer.render(frames: config.blockFrames, left: left, right: right)
            shared.write(left: left, right: right, frames: config.blockFrames)
        }
    }

    /// Drops buffered audio and restarts the mix at `frame`, while the audio callback outputs silence.
    func flush(renderer: SetRenderer, toFrame frame: Int) {
        shared.flushing.store(true, ordering: .releasing)
        let deadline = Date().addingTimeInterval(0.2)
        while !shared.flushAcknowledged.load(ordering: .acquiring), engine.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        shared.reset(baseFrame: frame)
        renderer.seek(toFrame: frame)
        shared.flushAcknowledged.store(false, ordering: .releasing)
        shared.flushing.store(false, ordering: .releasing)
    }
}

/// State shared between the producer thread and the real-time audio callback.
/// The callback never locks or allocates: it reads atomics and copies samples.
private final class SharedState: @unchecked Sendable {
    enum Command {
        case layout(SetLayout)
        case seek(TimeInterval)
    }

    let commands = Mutex<[Command]>([])
    let running = Atomic<Bool>(true)
    let playing = Atomic<Bool>(false)
    let flushing = Atomic<Bool>(false)
    let flushAcknowledged = Atomic<Bool>(false)
    /// Set frame of the first sample written after the last flush, and frames played since.
    let baseFrame = Atomic<Int>(0)
    let consumed = Atomic<Int>(0)

    private let capacity: Int
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    /// Monotonic counters; the ring index is the counter modulo `capacity`.
    private let written = Atomic<Int>(0)
    private let read = Atomic<Int>(0)

    init(capacity: Int) {
        self.capacity = capacity
        left = .allocate(capacity: capacity)
        right = .allocate(capacity: capacity)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    var playheadFrame: Int { baseFrame.load(ordering: .acquiring) + consumed.load(ordering: .acquiring) }

    var freeFrames: Int { capacity - (written.load(ordering: .acquiring) - read.load(ordering: .acquiring)) }

    /// Producer side.
    func write(left source: UnsafePointer<Float>, right sourceRight: UnsafePointer<Float>, frames: Int) {
        let start = written.load(ordering: .relaxed)
        for i in 0..<frames {
            let index = (start + i) % capacity
            left[index] = source[i]
            right[index] = sourceRight[i]
        }
        written.store(start + frames, ordering: .releasing)
    }

    /// Producer side, only while the callback is parked by `flushing`.
    func reset(baseFrame frame: Int) {
        written.store(0, ordering: .releasing)
        read.store(0, ordering: .releasing)
        baseFrame.store(frame, ordering: .releasing)
        consumed.store(0, ordering: .releasing)
    }

    /// Audio callback side.
    func consume(left output: UnsafeMutablePointer<Float>, right outputRight: UnsafeMutablePointer<Float>, frames: Int) {
        if flushing.load(ordering: .acquiring) {
            flushAcknowledged.store(true, ordering: .releasing)
            output.update(repeating: 0, count: frames)
            outputRight.update(repeating: 0, count: frames)
            return
        }
        var copied = 0
        if playing.load(ordering: .acquiring) {
            let start = read.load(ordering: .relaxed)
            copied = min(frames, written.load(ordering: .acquiring) - start)
            for i in 0..<copied {
                let index = (start + i) % capacity
                output[i] = left[index]
                outputRight[i] = right[index]
            }
            read.store(start + copied, ordering: .releasing)
            consumed.add(copied, ordering: .releasing)
        }
        if copied < frames {
            (output + copied).update(repeating: 0, count: frames - copied)
            (outputRight + copied).update(repeating: 0, count: frames - copied)
        }
    }
}
