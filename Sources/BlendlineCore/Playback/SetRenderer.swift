import Foundation

/// Mixes a `SetLayout` into stereo audio, block by block from any position. Every track is
/// stretched to the set tempo and shaped by its transitions: an equal-power fade on each side and
/// a bass swap (the incoming lows stay killed until the swap bar, the outgoing ones go after it).
/// Used by the player in real time and by export offline. Not thread-safe.
public final class SetRenderer {
    /// Frames a track fades in or out over where an edit or a jump cuts it, and crossfades over where a
    /// tempo change restarts it, so the cut does not click.
    public static let declickFrames = 128

    public let sampleRate: Double
    public private(set) var layout: SetLayout
    public private(set) var position = 0
    /// An edit that changes what plays now waits for the next bar line: the layout, that frame, and
    /// the tracks it stops there.
    private var pending: (layout: SetLayout, atFrame: Int, stopping: Set<UUID>)?

    private let sources: SourceCache
    private let maxFrames: Int
    private let prefetchSeconds: Double
    private var voices: [UUID: Voice] = [:]
    private let scratch: [UnsafeMutablePointer<Float>]
    private let crossfadeScratch: [UnsafeMutablePointer<Float>]

    private final class Voice {
        var entry: PlacedEntry
        var stretcher: StretchedSource
        var equalizers: [DJEqualizer]
        /// Starts on an edit's bar line, over other tracks, so it fades in.
        var fadesIn = false
        /// The stretcher a tempo change replaced, heard while `stretcher` fades in over it, and the
        /// frames of that crossfade rendered so far.
        var replaced: StretchedSource?
        var crossfaded = 0

        init(entry: PlacedEntry, stretcher: StretchedSource, equalizers: [DJEqualizer]) {
            self.entry = entry
            self.stretcher = stretcher
            self.equalizers = equalizers
        }

        /// Renders the next `frames` of the track, crossfading from the replaced stretcher if any.
        func render(into output: [UnsafeMutablePointer<Float>], frames: Int, scratch: [UnsafeMutablePointer<Float>]) {
            stretcher.render(into: output, frames: frames)
            guard let replaced else { return }
            let length = min(SetRenderer.declickFrames - crossfaded, frames)
            replaced.render(into: scratch, frames: length)
            for i in 0..<length {
                let gain = Float(crossfaded + i) / Float(SetRenderer.declickFrames)
                for (channel, old) in zip(output, scratch) { channel[i] = channel[i] * gain + old[i] * (1 - gain) }
            }
            crossfaded += length
            if crossfaded == SetRenderer.declickFrames {
                self.replaced = nil
                crossfaded = 0
            }
        }
    }

    public init(layout: SetLayout, sources: SourceCache, config: AppConfig.Playback) {
        self.layout = layout
        self.sources = sources
        sampleRate = config.sampleRate
        maxFrames = config.blockFrames
        prefetchSeconds = config.prefetchSeconds
        scratch = (0..<2).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: config.blockFrames) }
        crossfadeScratch = (0..<2).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: config.blockFrames) }
    }

    deinit { (scratch + crossfadeScratch).forEach { $0.deallocate() } }

    public var framesPerBar: Double { layout.barDuration * sampleRate }
    public var framesPerBeat: Double { framesPerBar / 4 }

    /// The frame of the bar line an edit waits for; the block before it must end there.
    public var pendingUpdateFrame: Int? { pending?.atFrame }

    /// Moves to `frame`; an edit waiting for its bar line takes effect at once.
    public func seek(toFrame frame: Int) {
        if let pending { layout = pending.layout }
        pending = nil
        position = max(0, frame)
        voices.removeAll()
    }

    /// Switches to an edited layout and returns how many frames the position moved.
    ///
    /// What plays now is protected: an edit that leaves it as it is, give or take a shift by whole
    /// bars (a track before it removed, say), applies at once and moves the position along with it,
    /// without a break. One that changes it waits for the next bar line, where only the tracks it
    /// changes are cut. A tempo change goes on at the same place in what plays when the edit keeps
    /// it (a track before it removed, say), each track crossfading into a restart at the new tempo,
    /// else on the same bar of the set with every track restarted; it does not count as a move, since
    /// the position is in other frames anyway.
    public func update(_ newLayout: SetLayout) -> Int {
        let current = pending?.layout ?? layout
        pending = nil
        if newLayout.bpm != current.bpm {
            let bar = Double(position) / framesPerBar
            guard let shift = newLayout.shift(from: layout, atBar: bar) else {
                layout = newLayout
                position = frame(ofBar: bar)
                voices.removeAll()
                return 0
            }
            apply(newLayout, shiftedBy: shift)
            position = frame(ofBar: bar + Double(shift))
            for voice in voices.values {
                guard let grid = voice.entry.grid else { continue }
                // A crossfade not yet heard keeps fading from what was heard.
                if voice.replaced == nil || voice.crossfaded > 0 { voice.replaced = voice.stretcher }
                voice.crossfaded = 0
                voice.stretcher = stretcher(for: voice.entry, grid: grid, source: voice.stretcher.source,
                                            at: max(position, frame(ofBar: Double(voice.entry.startBar))))
            }
            return 0
        }
        let bar = Double(position) / framesPerBar
        if let shift = newLayout.shift(from: layout, atBar: bar) {
            apply(newLayout, shiftedBy: shift)
            let moved = frame(ofBar: Double(shift))
            position += moved
            return moved
        }
        let edited = Dictionary(uniqueKeysWithValues: newLayout.entries.map { ($0.id, $0) })
        let stopping = voices.keys.filter { id in
            guard let entry = edited[id], let voice = voices[id] else { return true }
            return entry.file != voice.entry.file || entry.grid != voice.entry.grid || entry.trackOrigin != voice.entry.trackOrigin
        }
        let nextBar = frame(ofBar: bar.rounded(.down) + 1)
        pending = (newLayout, nextBar > position ? nextBar : frame(ofBar: bar.rounded(.down) + 2), Set(stopping))
        return 0
    }

    /// Plays `newLayout` from here, keeping every track that moved by `shift` bars along with
    /// what plays now, so it goes on at the same place in its audio.
    private func apply(_ newLayout: SetLayout, shiftedBy shift: Int) {
        let edited = Dictionary(uniqueKeysWithValues: newLayout.entries.map { ($0.id, $0) })
        layout = newLayout
        voices = voices.compactMapValues { voice in
            guard let entry = edited[voice.entry.id], entry.file == voice.entry.file, entry.grid == voice.entry.grid,
                  entry.trackOrigin - voice.entry.trackOrigin == shift else { return nil }
            voice.entry = entry
            return voice
        }
    }

    /// Mixes the next `frames` (at most the configured block size) into `left` and `right`.
    public func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        precondition(frames <= maxFrames, "Render block larger than configured")
        var fadesIn = false
        if let due = pending, due.atFrame == position {
            pending = nil
            voices = voices.filter { !due.stopping.contains($0.key) }
            layout = due.layout
            let edited = Dictionary(uniqueKeysWithValues: layout.entries.map { ($0.id, $0) })
            for voice in voices.values { voice.entry = edited[voice.entry.id] ?? voice.entry }
            fadesIn = true
        }
        precondition(pending.map { position + frames <= $0.atFrame } ?? true, "Render block crosses the bar line an edit waits for")
        left.initialize(repeating: 0, count: frames)
        right.initialize(repeating: 0, count: frames)
        let blockEnd = position + frames
        let fadesOut = pending.flatMap { $0.atFrame == blockEnd ? $0.stopping : nil } ?? []
        var active = Set<UUID>()

        for (index, entry) in layout.entries.enumerated() where entry.grid != nil {
            let start = frame(ofBar: Double(entry.startBar))
            let end = frame(ofBar: Double(entry.endBar))
            guard start < blockEnd, end > position else { continue }
            let isNew = voices[entry.id] == nil
            guard let voice = voice(for: entry, at: max(position, start)) else { continue }
            if isNew, fadesIn, start < position { voice.fadesIn = true }
            active.insert(entry.id)

            let from = max(position, start) - position
            let to = min(blockEnd, end) - position
            let next = index + 1 < layout.entries.count ? layout.entries[index + 1] : nil
            voice.render(into: scratch.map { $0 + from }, frames: to - from, scratch: crossfadeScratch)
            if voice.fadesIn {
                voice.fadesIn = false
                Self.ramp(scratch.map { $0 + from }, frames: to - from, fadingIn: true)
            }
            if fadesOut.contains(entry.id), to == frames { Self.ramp(scratch.map { $0 + from }, frames: to - from, fadingIn: false) }
            let gainsFrom = gains(for: entry, next: next, atFrame: position + from)
            let gainsTo = gains(for: entry, next: next, atFrame: position + to - 1)
            voice.equalizers[0].process(scratch[0] + from, frames: to - from, from: gainsFrom, to: gainsTo, addingInto: left + from)
            voice.equalizers[1].process(scratch[1] + from, frames: to - from, from: gainsFrom, to: gainsTo, addingInto: right + from)
        }
        voices = voices.filter { active.contains($0.key) }
        Self.softClip(left, frames)
        Self.softClip(right, frames)
        position = blockEnd
        prefetchUpcoming()
    }

    private func frame(ofBar bar: Double) -> Int { Int((bar * framesPerBar).rounded()) }

    /// Fades the first `declickFrames` of `channels` in, or their last ones out.
    static func ramp(_ channels: [UnsafeMutablePointer<Float>], frames: Int, fadingIn: Bool) {
        let length = min(declickFrames, frames)
        for i in 0..<length {
            let gain = Float(i) / Float(length)
            let index = fadingIn ? i : frames - 1 - i
            for channel in channels { channel[index] *= gain }
        }
    }

    private func voice(for entry: PlacedEntry, at frame: Int) -> Voice? {
        if let voice = voices[entry.id] { return voice }
        guard let grid = entry.grid, let source = try? sources.buffer(for: entry.file) else { return nil }
        let voice = Voice(entry: entry, stretcher: stretcher(for: entry, grid: grid, source: source, at: frame),
                          equalizers: (0..<2).map { _ in DJEqualizer(sampleRate: sampleRate, maxFrames: maxFrames) })
        voices[entry.id] = voice
        return voice
    }

    /// `entry`'s audio stretched to the set tempo, starting at set frame `frame`.
    private func stretcher(for entry: PlacedEntry, grid: BeatGrid, source: PCMBuffer, at frame: Int) -> StretchedSource {
        let stretcher = StretchedSource(source: source, ratio: grid.bpm / layout.bpm)
        let trackBar = Double(entry.cueInBar) + Double(frame) / framesPerBar - Double(entry.startBar)
        let sourceTime = grid.firstDownbeat + trackBar * grid.barDuration
        stretcher.seek(toSourceFrame: Int((sourceTime * source.sampleRate).rounded()))
        return stretcher
    }

    func gains(for entry: PlacedEntry, next: PlacedEntry?, atFrame frame: Int) -> MixGains {
        TransitionCurves.gains(for: entry, next: next, atBar: Double(frame) / framesPerBar)
    }

    /// Starts decoding the tracks that play soon after `frame`, so a jump there finds them ready.
    public func prefetch(from frame: Int) {
        for entry in upcoming(from: frame) { sources.prefetch(entry.file) }
    }

    private func prefetchUpcoming() {
        for entry in upcoming(from: position) where voices[entry.id] == nil { sources.prefetch(entry.file) }
    }

    /// Tracks that play within the prefetch horizon from `frame`.
    private func upcoming(from frame: Int) -> [PlacedEntry] {
        let horizon = frame + Int(prefetchSeconds * sampleRate)
        return layout.entries.filter { entry in
            entry.grid != nil && self.frame(ofBar: Double(entry.startBar)) <= horizon && self.frame(ofBar: Double(entry.endBar)) > frame
        }
    }

    /// Transparent below 0.8, then a tanh knee that never exceeds 1.
    static func softClip(_ samples: UnsafeMutablePointer<Float>, _ frames: Int) {
        for i in 0..<frames {
            let x = samples[i]
            let magnitude = abs(x)
            if magnitude > 0.8 { samples[i] = (0.8 + 0.2 * tanh((magnitude - 0.8) / 0.2)) * (x < 0 ? -1 : 1) }
        }
    }
}
