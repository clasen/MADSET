import Foundation

/// Mixes a `SetLayout` into stereo audio, block by block from any position. Every track is
/// stretched to the set tempo and shaped by its transitions: an equal-power fade on each side and
/// a bass swap (the incoming lows stay killed until the swap bar, the outgoing ones go after it).
/// Used by the player in real time and by export offline. Not thread-safe.
public final class SetRenderer {
    public let sampleRate: Double
    public private(set) var layout: SetLayout
    public private(set) var position = 0

    private let sources: SourceCache
    private let maxFrames: Int
    private let prefetchSeconds: Double
    private var voices: [UUID: Voice] = [:]
    private let scratch: [UnsafeMutablePointer<Float>]

    private final class Voice {
        let entry: PlacedEntry
        let stretcher: StretchedSource
        var equalizers: [DJEqualizer]

        init(entry: PlacedEntry, stretcher: StretchedSource, equalizers: [DJEqualizer]) {
            self.entry = entry
            self.stretcher = stretcher
            self.equalizers = equalizers
        }
    }

    public init(layout: SetLayout, sources: SourceCache, config: AppConfig.Playback) {
        self.layout = layout
        self.sources = sources
        sampleRate = config.sampleRate
        maxFrames = config.blockFrames
        prefetchSeconds = config.prefetchSeconds
        scratch = (0..<2).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: config.blockFrames) }
    }

    deinit { scratch.forEach { $0.deallocate() } }

    public var framesPerBar: Double { layout.barDuration * sampleRate }
    public var framesPerBeat: Double { framesPerBar / 4 }

    public func seek(toFrame frame: Int) {
        position = max(0, frame)
        voices.removeAll()
    }

    /// Switches to an edited layout at the current position. Tracks whose placement is unchanged
    /// keep playing seamlessly; the others restart where the new layout puts them.
    public func update(_ newLayout: SetLayout) {
        let tempoChanged = newLayout.bpm != layout.bpm
        if tempoChanged {
            let bar = Double(position) / framesPerBar
            layout = newLayout
            position = Int(bar * framesPerBar)
            voices.removeAll()
            return
        }
        layout = newLayout
        let current = Dictionary(uniqueKeysWithValues: newLayout.entries.map { ($0.id, $0) })
        voices = voices.filter { id, voice in current[id] == voice.entry }
    }

    /// Mixes the next `frames` (at most the configured block size) into `left` and `right`.
    public func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        precondition(frames <= maxFrames, "Render block larger than configured")
        left.initialize(repeating: 0, count: frames)
        right.initialize(repeating: 0, count: frames)
        let blockEnd = position + frames
        var active = Set<UUID>()

        for (index, entry) in layout.entries.enumerated() where entry.grid != nil {
            let start = frame(ofBar: Double(entry.startBar))
            let end = frame(ofBar: Double(entry.endBar))
            guard start < blockEnd, end > position else { continue }
            guard let voice = voice(for: entry, at: max(position, start)) else { continue }
            active.insert(entry.id)

            let from = max(position, start) - position
            let to = min(blockEnd, end) - position
            let next = index + 1 < layout.entries.count ? layout.entries[index + 1] : nil
            voice.stretcher.render(into: scratch.map { $0 + from }, frames: to - from)
            let gainsFrom = gains(for: entry, next: next, atFrame: position + from)
            let gainsTo = gains(for: entry, next: next, atFrame: position + to - 1)
            voice.equalizers[0].process(scratch[0] + from, frames: to - from, from: gainsFrom, to: gainsTo, addingInto: left + from)
            voice.equalizers[1].process(scratch[1] + from, frames: to - from, from: gainsFrom, to: gainsTo, addingInto: right + from)
        }
        voices = voices.filter { active.contains($0.key) }
        softClip(left, frames)
        softClip(right, frames)
        position = blockEnd
        prefetchUpcoming()
    }

    private func frame(ofBar bar: Double) -> Int { Int((bar * framesPerBar).rounded()) }

    private func voice(for entry: PlacedEntry, at frame: Int) -> Voice? {
        if let voice = voices[entry.id] { return voice }
        guard let grid = entry.grid, let source = try? sources.buffer(for: entry.file) else { return nil }
        let stretcher = StretchedSource(source: source, ratio: grid.bpm / layout.bpm)
        let trackBar = Double(entry.cueInBar) + Double(frame) / framesPerBar - Double(entry.startBar)
        let sourceTime = grid.firstDownbeat + trackBar * grid.barDuration
        stretcher.seek(toSourceFrame: Int((sourceTime * source.sampleRate).rounded()))
        let voice = Voice(entry: entry, stretcher: stretcher, equalizers: (0..<2).map { _ in DJEqualizer(sampleRate: sampleRate, maxFrames: maxFrames) })
        voices[entry.id] = voice
        return voice
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
    private func softClip(_ samples: UnsafeMutablePointer<Float>, _ frames: Int) {
        for i in 0..<frames {
            let x = samples[i]
            let magnitude = abs(x)
            if magnitude > 0.8 { samples[i] = (0.8 + 0.2 * tanh((magnitude - 0.8) / 0.2)) * (x < 0 ? -1 : 1) }
        }
    }
}
