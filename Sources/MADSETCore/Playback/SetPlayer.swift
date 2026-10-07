@preconcurrency import AVFoundation
import Foundation
import Synchronization

/// Plays a `SetLayout`. A producer thread mixes ahead of the playhead into a ring buffer; the audio
/// callback only copies from it. Layout edits reach the producer without interrupting tracks whose
/// placement is unchanged; seeks and tempo changes flush the buffer. Playing starts once audio is
/// buffered; a player that follows another one then waits for its beat, to play in phase with it, and
/// can mix in what the other one plays, as it is heard, for a cue mix.
public final class SetPlayer: @unchecked Sendable {
    private let config: AppConfig.Playback
    private let engine: AVAudioEngine
    private let shared: SharedState
    /// Where the set's beats are heard while it plays.
    public let clock: PlayheadClock
    /// What it plays, as it is heard, for a player that follows it.
    public let heard: HeardAudio
    private let reference: PlayheadClock?
    /// First of the two device channels the player plays through, from 0.
    private let firstChannel = Atomic<Int>(0)
    private var configurationObserver: NSObjectProtocol?

    /// `engine` is injectable so tests can render without a sound device (manual rendering mode).
    /// Following `reference`, every start waits for a beat of it while it plays, at the same place in
    /// the bar, and `setLevels` mixes in what it plays.
    public init(config: AppConfig.Playback, sources: SourceCache, engine: AVAudioEngine = AVAudioEngine(),
                following reference: SetPlayer? = nil) throws {
        self.config = config
        self.engine = engine
        self.reference = reference?.clock
        clock = PlayheadClock(sampleRate: config.sampleRate)
        heard = HeardAudio(sampleRate: config.sampleRate, writeAhead: config.blockFrames)
        shared = SharedState(capacity: Int(config.bufferSeconds * config.sampleRate) + config.blockFrames,
                             sampleRate: config.sampleRate, clock: clock, heard: heard,
                             reference: reference.map { ($0.clock, $0.heard) })

        guard let format = AVAudioFormat(standardFormatWithSampleRate: config.sampleRate, channels: 2) else {
            preconditionFailure("Unsupported playback format")
        }
        let shared = shared
        let source = AVAudioSourceNode(format: format) { _, timestamp, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            let left = buffers[0].mData!.assumingMemoryBound(to: Float.self)
            let right = buffers[1].mData!.assumingMemoryBound(to: Float.self)
            shared.consume(left: left, right: right, frames: Int(frameCount), at: timestamp.pointee)
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        connectOutput()
        try engine.start()
        clock.setOutputLatency(engine.outputNode.presentationLatency)

        // Switching the output device stops the engine; restart it on the new device.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            connectOutput()
            try? engine.start()
            clock.setOutputLatency(engine.outputNode.presentationLatency)
        }

        // The thread holds only what it needs, so releasing the player stops it.
        let thread = Thread { Producer(shared: shared, config: config, sources: sources, engine: engine).run() }
        thread.qualityOfService = .userInteractive
        thread.name = "MADSET mixer"
        thread.start()
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        shared.running.store(false, ordering: .releasing)
        engine.stop()
    }

    /// Playing, or about to: waiting for a full buffer or for the reference's beat.
    public var isPlaying: Bool { shared.transport.load(ordering: .acquiring) != Transport.paused.rawValue }

    /// Seconds into the set at the playhead.
    public var currentTime: TimeInterval { Double(shared.playheadFrame) / config.sampleRate }

    /// Where a move asked for while playing goes on from, until it is heard.
    public var pendingMove: TimeInterval? {
        let frame = shared.requestedJump.load(ordering: .acquiring)
        return frame < 0 ? nil : Double(frame) / config.sampleRate
    }

    /// Plays on from the playhead, after the seeks and edits asked for before. Starts the engine again
    /// if a device change left it stopped and the restart then failed.
    public func play() throws {
        if !engine.isRunning { try engine.start() }
        shared.transport.store(Transport.requested.rawValue, ordering: .releasing)
        shared.commands.withLock { $0.append(.start) }
    }

    /// Plays from `time`; while the reference plays, from `time` moved ahead by less than a bar, so it
    /// comes in at the same place in the bar on the reference's first beat a buffer's length from now.
    public func play(from time: TimeInterval) throws {
        if let position = reference?.position {
            let soon = position.beat + (HostTime.now + config.bufferSeconds - position.hostTime) * position.beatsPerSecond
            seek(to: PhaseAlignment.start(time, beatDuration: 1 / position.beatsPerSecond, inPhaseWith: soon.rounded(.up)))
        } else {
            seek(to: time)
        }
        try play()
    }

    public func pause() { shared.transport.store(Transport.paused.rawValue, ordering: .releasing) }

    /// Audio is coming out: not paused, nor waiting to start.
    public var isSounding: Bool { shared.isSounding }

    /// While audio comes out, goes on at the next bar line from `bars` bars past it, without a gap and
    /// within the set; moves asked for before it gets there add up. Otherwise see `move(to:)`.
    public func move(byBars bars: Int) {
        shared.commands.withLock { $0.append(.jumpBy(bars)) }
    }

    /// Gains of its own audio and of what the player it follows plays; see `CueMix`. They apply from
    /// the next audio buffer on, gliding over it.
    public func setLevels(own: Float, reference: Float) {
        shared.ownGain.store(own.bitPattern, ordering: .releasing)
        shared.referenceGain.store(reference.bitPattern, ordering: .releasing)
    }

    /// Moves the playhead to `time`, the start of a bar. While audio plays, it plays on to the next
    /// bar line and goes on from `time` there, without a gap and keeping its phase; a player about to
    /// start comes in from `time` instead, and a paused one just moves.
    public func move(to time: TimeInterval) throws {
        switch Transport(rawValue: shared.transport.load(ordering: .acquiring)) {
        case .playing:
            shared.commands.withLock {
                shared.requestedJump.store(Self.frame(of: time, sampleRate: config.sampleRate), ordering: .releasing)
                $0.append(.jump(time))
            }
        case .requested, .armed: try play(from: time)
        case .paused, nil: seek(to: time)
        }
    }

    /// Plays through `device`, on its channel `firstChannel` (from 0) and the next one, from now on;
    /// what is buffered keeps its place.
    public func setOutput(_ device: AudioDeviceID, firstChannel: Int) throws {
        let output = engine.outputNode
        guard output.auAudioUnit.deviceID != device || self.firstChannel.load(ordering: .acquiring) != firstChannel else { return }
        engine.stop()
        try output.auAudioUnit.setDeviceID(device)
        self.firstChannel.store(firstChannel, ordering: .releasing)
        connectOutput()
        try engine.start()
        clock.setOutputLatency(output.presentationLatency)
    }

    /// Feeds the device the set in stereo, on the chosen pair of its channels; the others stay silent.
    /// A device that has no such pair (it changed under the player) gets silence until `setOutput` again.
    private func connectOutput() {
        let output = engine.outputNode
        let device = output.outputFormat(forBus: 0)
        guard let stereo = AVAudioFormat(standardFormatWithSampleRate: device.sampleRate, channels: 2) else {
            preconditionFailure("Unsupported output format")
        }
        engine.connect(engine.mainMixerNode, to: output, format: stereo)
        guard !engine.isInManualRenderingMode else { return }
        let channels = Int(device.channelCount)
        let first = firstChannel.load(ordering: .acquiring)
        let fits = first + 2 <= channels || (first == 0 && channels == 1)
        output.auAudioUnit.channelMap = (0..<channels).map { channel in
            NSNumber(value: fits && (channel == first || channel == first + 1) ? channel - first : -1)
        }
    }

    /// The set frame of `time`, the same way for a jump asked for and the one the producer makes.
    fileprivate static func frame(of time: TimeInterval, sampleRate: Double) -> Int { Int((time * sampleRate).rounded()) }

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
        /// The jump asked for: set frame to go on from, and the frame of the bar line to leave at.
        var jump: (target: Int, at: Int)?
        var fadesIn = false
        let left = UnsafeMutablePointer<Float>.allocate(capacity: config.blockFrames)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: config.blockFrames)
        defer {
            left.deallocate()
            right.deallocate()
        }
        while shared.running.load(ordering: .acquiring) {
            var start = false
            for command in shared.commands.withLock({ pending in defer { pending.removeAll() }; return pending }) {
                switch command {
                case .start:
                    start = true
                case .jump(let time):
                    guard let renderer else { continue }
                    let target = SetPlayer.frame(of: time, sampleRate: config.sampleRate)
                    jump = (target, nextBarLine(of: renderer))
                    renderer.prefetch(from: target)
                case .jumpBy(let bars):
                    guard let renderer else { continue }
                    let at = jump?.at ?? nextBarLine(of: renderer)
                    let from = Double(jump?.target ?? at) / renderer.framesPerBar
                    let bar = min(max(0, from.rounded() + Double(bars)), Double(max(0, renderer.layout.totalBars - 1)))
                    let target = Int((bar * renderer.framesPerBar).rounded())
                    jump = (target, at)
                    shared.requestedJump.store(target, ordering: .releasing)
                    renderer.prefetch(from: target)
                case .layout(let layout):
                    guard let current = renderer else {
                        let created = SetRenderer(layout: layout, sources: sources, config: config)
                        shared.clock.setFramesPerBeat(created.framesPerBeat)
                        renderer = created
                        continue
                    }
                    if current.layout.bpm != layout.bpm {
                        // Restarts at the new tempo on what is heard now, wherever the edit moved it.
                        jump = nil
                        let heard = Double(shared.playheadFrame) / current.framesPerBar
                        let bar = heard + Double(layout.shift(from: current.layout, atBar: heard) ?? 0)
                        _ = current.update(layout)
                        flush(renderer: current, toFrame: Int(bar * current.framesPerBar))
                    } else {
                        let moved = current.update(layout)
                        if moved != 0 {
                            jump?.at += moved
                            follow(renderer: current, movedBy: moved)
                        }
                    }
                case .seek(let time):
                    jump = nil
                    if let renderer { flush(renderer: renderer, toFrame: Int(time * config.sampleRate)) }
                }
            }
            // Armed only after the batch, so a seek that came with the start is not preceded by stale audio.
            // A pause since then wins.
            if start {
                _ = shared.transport.compareExchange(expected: Transport.requested.rawValue, desired: Transport.armed.rawValue, ordering: .acquiringAndReleasing)
            }
            guard let renderer, shared.freeFrames >= config.blockFrames else {
                Thread.sleep(forTimeInterval: 0.002)
                continue
            }
            if let pending = jump, renderer.position >= pending.at {
                // The callback takes one jump at a time; it is at most a buffer away.
                guard !shared.jumpPending else {
                    Thread.sleep(forTimeInterval: 0.002)
                    continue
                }
                shared.jump(toFrame: pending.target)
                renderer.seek(toFrame: pending.target)
                jump = nil
                fadesIn = true
            }
            // Blocks end on the bar line a jump or an edit waits for.
            let lines = [jump?.at, renderer.pendingUpdateFrame].compactMap { $0 }.filter { $0 > renderer.position }
            let frames = min(config.blockFrames, lines.map { $0 - renderer.position }.min() ?? config.blockFrames)
            let fadesOut = jump.map { renderer.position + frames == $0.at } ?? false
            renderer.render(frames: frames, left: left, right: right)
            if fadesOut { SetRenderer.ramp([left, right], frames: frames, fadingIn: false) }
            if fadesIn { SetRenderer.ramp([left, right], frames: frames, fadingIn: true) }
            fadesIn = false
            shared.write(left: left, right: right, frames: frames)
        }
    }


    /// The first bar line the renderer has not rendered yet.
    private func nextBarLine(of renderer: SetRenderer) -> Int {
        var bar = (Double(renderer.position) / renderer.framesPerBar).rounded(.down) + 1
        if Int((bar * renderer.framesPerBar).rounded()) <= renderer.position { bar += 1 }
        return Int((bar * renderer.framesPerBar).rounded())
    }

    /// Keeps the playhead on what plays after an edit moved it `frames` along the set: from the next
    /// frame written while playing, so it goes on without a break; otherwise at once.
    func follow(renderer: SetRenderer, movedBy frames: Int) {
        // The callback takes one jump at a time; it is at most a buffer away.
        while shared.jumpPending, shared.isSounding { Thread.sleep(forTimeInterval: 0.001) }
        if shared.isSounding {
            shared.jump(toFrame: renderer.position)
        } else {
            flush(renderer: renderer, toFrame: shared.playheadFrame + frames)
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
        shared.clock.setFramesPerBeat(renderer.framesPerBeat)
        renderer.seek(toFrame: frame)
        shared.flushAcknowledged.store(false, ordering: .releasing)
        shared.flushing.store(false, ordering: .releasing)
    }
}

/// Where a player is between pause and play. `play()` asks; the producer arms the player once it has
/// handled the commands before; the audio callback starts it when audio is buffered and, following a
/// reference, when the reference's beat comes. Stored as its raw value in an atomic.
private enum Transport: Int {
    case paused, requested, armed, playing
}

/// State shared between the producer thread and the real-time audio callback.
/// The callback never locks or allocates: it reads atomics and copies samples.
private final class SharedState: @unchecked Sendable {
    enum Command {
        case layout(SetLayout)
        case seek(TimeInterval)
        case start
        /// Goes on from this time at the next bar line, without a gap.
        case jump(TimeInterval)
        /// Goes on at the next bar line from this many bars past it, or past where a jump waiting for
        /// it goes on from.
        case jumpBy(Int)
    }

    let clock: PlayheadClock
    let heard: HeardAudio
    /// The clock and the audio of the player this one follows.
    let reference: (clock: PlayheadClock, heard: HeardAudio)?
    let commands = Mutex<[Command]>([])
    let running = Atomic<Bool>(true)
    let transport = Atomic<Int>(Transport.paused.rawValue)
    let flushing = Atomic<Bool>(false)
    let flushAcknowledged = Atomic<Bool>(false)
    /// Set frame of the first sample written after the last flush, and frames played since.
    let baseFrame = Atomic<Int>(0)
    let consumed = Atomic<Int>(0)
    /// Set frame the last jump asked for goes on from, until it is played; -1 when none waits.
    let requestedJump = Atomic<Int>(-1)
    /// Bit patterns of the gains `setLevels` asks for.
    let ownGain = Atomic<UInt32>(Float(1).bitPattern)
    let referenceGain = Atomic<UInt32>(Float(0).bitPattern)
    /// `heard`'s count at the first frame written after the last flush.
    private let heardBase = Atomic<Int>(0)
    /// Audio callback only: the gains of the last buffer, and how far into the reference's audio it read.
    private var lastOwnGain: Float = 1
    private var lastReferenceGain: Float = 0
    private var referenceCursor: Int?

    private let capacity: Int
    private let sampleRate: Double
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    /// Monotonic counters; the ring index is the counter modulo `capacity`.
    private let written = Atomic<Int>(0)
    private let read = Atomic<Int>(0)
    /// A jump written into the buffer and not yet played: from the read count `jumpCount` on, the
    /// set frame is `jumpBase` plus the count.
    private let jumpIsPending = Atomic<Bool>(false)
    private let jumpCount = Atomic<Int>(0)
    private let jumpBase = Atomic<Int>(0)

    init(capacity: Int, sampleRate: Double, clock: PlayheadClock, heard: HeardAudio,
         reference: (clock: PlayheadClock, heard: HeardAudio)?) {
        self.capacity = capacity
        self.sampleRate = sampleRate
        self.clock = clock
        self.heard = heard
        self.reference = reference
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
        heard.write(left: source, right: sourceRight, frames: frames)
    }

    var jumpPending: Bool { jumpIsPending.load(ordering: .acquiring) }

    /// The callback is playing out of the buffer.
    var isSounding: Bool { transport.load(ordering: .acquiring) == Transport.playing.rawValue }

    /// Producer side, while no jump is pending: what is written from now on plays from set frame `frame`.
    func jump(toFrame frame: Int) {
        let count = written.load(ordering: .relaxed)
        jumpCount.store(count, ordering: .relaxed)
        jumpBase.store(frame - count, ordering: .relaxed)
        jumpIsPending.store(true, ordering: .releasing)
    }

    /// Producer side, only while the callback is parked by `flushing`. A pending jump goes with the
    /// audio it was written into.
    func reset(baseFrame frame: Int) {
        jumpIsPending.store(false, ordering: .releasing)
        requestedJump.store(-1, ordering: .releasing)
        heardBase.store(heard.count, ordering: .releasing)
        written.store(0, ordering: .releasing)
        read.store(0, ordering: .releasing)
        baseFrame.store(frame, ordering: .releasing)
        consumed.store(0, ordering: .releasing)
    }

    /// Audio callback side. While flushing, the clock keeps its last position: a tempo change flushes
    /// without moving the playhead in bars.
    func consume(left output: UnsafeMutablePointer<Float>, right outputRight: UnsafeMutablePointer<Float>, frames: Int,
                 at timestamp: AudioTimeStamp) {
        let gains = (own: Float(bitPattern: ownGain.load(ordering: .acquiring)), reference: Float(bitPattern: referenceGain.load(ordering: .acquiring)))
        defer {
            mixReference(into: output, outputRight, frames: frames, at: timestamp, gain: (lastReferenceGain, gains.reference))
            lastOwnGain = gains.own
            lastReferenceGain = gains.reference
        }
        if flushing.load(ordering: .acquiring) {
            flushAcknowledged.store(true, ordering: .releasing)
            heard.silence()
            output.update(repeating: 0, count: frames)
            outputRight.update(repeating: 0, count: frames)
            return
        }
        var playing = transport.load(ordering: .acquiring) == Transport.playing.rawValue
        var offset = 0
        if !playing, transport.load(ordering: .acquiring) == Transport.armed.rawValue, let start = startOffset(frames: frames, at: timestamp),
           transport.compareExchange(expected: Transport.armed.rawValue, desired: Transport.playing.rawValue, ordering: .acquiringAndReleasing).exchanged {
            playing = true
            offset = max(0, start)
            // A start that went by at most a buffer ago skips what has passed, so it stays in phase.
            read.add(max(0, -start), ordering: .releasing)
            consumed.add(max(0, -start), ordering: .releasing)
        }
        var copied = 0
        if playing {
            clock.publish(frame: playheadFrame - offset, at: timestamp)
            let start = read.load(ordering: .relaxed)
            if let heardAt = clock.heardTime(of: timestamp) {
                heard.publish(frame: heardBase.load(ordering: .acquiring) + start, heardAt: heardAt + Double(offset) / sampleRate)
            } else {
                heard.silence()
            }
            copied = min(frames - offset, written.load(ordering: .acquiring) - start)
            for i in 0..<copied {
                let index = (start + i) % capacity
                let gain = lastOwnGain + (gains.own - lastOwnGain) * Float(offset + i) / Float(frames)
                output[offset + i] = left[index] * gain
                outputRight[offset + i] = right[index] * gain
            }
            read.store(start + copied, ordering: .releasing)
            consumed.add(copied, ordering: .releasing)
            if jumpIsPending.load(ordering: .acquiring), start + copied >= jumpCount.load(ordering: .relaxed) {
                let base = jumpBase.load(ordering: .relaxed)
                baseFrame.store(base, ordering: .releasing)
                jumpIsPending.store(false, ordering: .releasing)
                // A later move asked for meanwhile still waits.
                _ = requestedJump.compareExchange(expected: base + jumpCount.load(ordering: .relaxed), desired: -1, ordering: .acquiringAndReleasing)
            }
        } else {
            clock.stop()
            heard.silence()
        }
        output.update(repeating: 0, count: offset)
        outputRight.update(repeating: 0, count: offset)
        if offset + copied < frames {
            (output + offset + copied).update(repeating: 0, count: frames - offset - copied)
            (outputRight + offset + copied).update(repeating: 0, count: frames - offset - copied)
        }
    }

    /// Audio callback side: adds what the followed player plays, as heard with this buffer, and keeps
    /// the sum from clipping.
    private func mixReference(into output: UnsafeMutablePointer<Float>, _ outputRight: UnsafeMutablePointer<Float>, frames: Int,
                              at timestamp: AudioTimeStamp, gain: (from: Float, to: Float)) {
        guard let reference, gain.from > 0 || gain.to > 0, let heardAt = clock.heardTime(of: timestamp) else {
            referenceCursor = nil
            return
        }
        referenceCursor = reference.heard.mix(into: output, outputRight, frames: frames, heardAt: heardAt, gain: gain, cursor: referenceCursor)
        SetRenderer.softClip(output, frames)
        SetRenderer.softClip(outputRight, frames)
    }

    /// Audio callback side, while armed: the frame of this buffer to start at once there is audio for it
    /// and for skipping a late start, in phase with the reference while it plays (negative when that went
    /// by within this buffer); nil to wait.
    private func startOffset(frames: Int, at timestamp: AudioTimeStamp) -> Int? {
        guard written.load(ordering: .acquiring) - read.load(ordering: .relaxed) >= 2 * frames else { return nil }
        guard let position = reference?.clock.position, let heard = clock.heardTime(of: timestamp) else { return 0 }
        let framesPerBeat = sampleRate / position.beatsPerSecond
        return PhaseAlignment.offset(startBeat: Double(playheadFrame) / framesPerBeat,
                                     referenceBeat: position.beat + (heard - position.hostTime) * position.beatsPerSecond,
                                     framesPerBeat: framesPerBeat, frames: frames)
    }
}
