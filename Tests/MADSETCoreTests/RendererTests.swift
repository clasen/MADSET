import Foundation
import Testing
@testable import MADSETCore

@Suite struct RendererTests {
    private let analysisConfig = AppConfig.current.analysis
    private var playback: AppConfig.Playback {
        var config = AppConfig.current.playback
        config.sampleRate = Synth.sampleRate
        return config
    }

    /// Two synthetic tracks at different tempos, analyzed for real, placed with an automatic transition.
    private func twoTrackSet(bpm: Double) throws -> (SetLayout, SourceCache) {
        let a = Synth.track(bpm: 124, bars: 48, leadIn: 0.3) { $0 < 40 ? [.kick, .bass, .hats] : [.kick, .hats] }
        let b = Synth.track(bpm: 130, bars: 48, leadIn: 0.7) { $0 < 16 ? [.kick, .hats] : [.kick, .bass, .hats, .pad] }
        let urls = [URL(filePath: "/synthetic/a.wav"), URL(filePath: "/synthetic/b.wav")]
        let audio = [urls[0]: a, urls[1]: b]
        let entries = urls.map { SetEntry(file: $0) }
        var tracks: [UUID: SetLayout.TrackInfo] = [:]
        for entry in entries {
            let analysis = try TrackAnalyzer.analyze(samples: audio[entry.file]!, needsKey: false, config: analysisConfig)
            tracks[entry.id] = .init(analysis: analysis, duration: analysis.duration)
        }
        let layout = SetLayout(bpm: bpm, entries: entries, tracks: tracks, phraseBars: 8)
        let sources = SourceCache(capacity: 2, sampleRate: Synth.sampleRate) { url, _ in
            PCMBuffer(channels: [audio[url]!, audio[url]!], sampleRate: Synth.sampleRate)
        }
        return (layout, sources)
    }

    private func render(_ renderer: SetRenderer, frames total: Int) -> [Float] {
        var left = [Float](repeating: 0, count: total)
        var right = [Float](repeating: 0, count: total)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                var offset = 0
                while offset < total {
                    let n = min(playback.blockFrames, total - offset)
                    renderer.render(frames: n, left: l.baseAddress! + offset, right: r.baseAddress! + offset)
                    offset += n
                }
            }
        }
        return left
    }

    @Test func mixesBothTracksOnTheSetGrid() throws {
        let (layout, sources) = try twoTrackSet(bpm: 126)
        #expect(layout.entries[1].overlapBars == 16)

        let renderer = SetRenderer(layout: layout, sources: sources, config: playback)
        let framesPerBar = renderer.framesPerBar
        let mix = render(renderer, frames: Int(Double(layout.totalBars) * framesPerBar))

        let beat = 60 / 126.0
        func phaseError(bars: Range<Int>) throws -> Double {
            let segment = Array(mix[Int(Double(bars.lowerBound) * framesPerBar)..<Int(Double(bars.upperBound) * framesPerBar)])
            let analysis = try TrackAnalyzer.analyze(samples: segment, needsKey: false, config: analysisConfig)
            #expect(abs(analysis.grid.bpm - 126) < 0.05)
            var error = analysis.grid.firstDownbeat.truncatingRemainder(dividingBy: beat)
            if error > beat / 2 { error -= beat }
            return error
        }
        let transition = layout.entries[1].startBar
        #expect(abs(try phaseError(bars: 0..<transition)) < 0.012)
        #expect(abs(try phaseError(bars: transition..<(transition + layout.entries[1].overlapBars))) < 0.012)
        #expect(abs(try phaseError(bars: (transition + 8)..<layout.totalBars)) < 0.012)
        #expect(mix.allSatisfy { abs($0) <= 1 })
    }

    @Test func transitionFadesAndSwapsTheBass() throws {
        let (layout, sources) = try twoTrackSet(bpm: 126)
        let renderer = SetRenderer(layout: layout, sources: sources, config: playback)
        let (outgoing, incoming) = (layout.entries[0], layout.entries[1])
        let frame = { (bar: Double) in Int(bar * renderer.framesPerBar) }
        let start = Double(incoming.startBar)
        let swap = start + Double(incoming.bassSwapBar)
        let end = start + Double(incoming.overlapBars)

        let atStart = (renderer.gains(for: incoming, next: nil, atFrame: frame(start)), renderer.gains(for: outgoing, next: incoming, atFrame: frame(start)))
        #expect(atStart.0.volume == 0 && atStart.0.low == 0)
        #expect(atStart.1 == MixGains())

        let beforeSwap = (renderer.gains(for: incoming, next: nil, atFrame: frame(swap - 0.5)), renderer.gains(for: outgoing, next: incoming, atFrame: frame(swap - 0.5)))
        #expect(beforeSwap.0.volume == 1 && beforeSwap.0.low == 0)
        #expect(beforeSwap.1.low == 1)

        let afterSwap = (renderer.gains(for: incoming, next: nil, atFrame: frame(swap + 0.5)), renderer.gains(for: outgoing, next: incoming, atFrame: frame(swap + 0.5)))
        #expect(afterSwap.0.low == 1)
        #expect(afterSwap.1.low == 0 && afterSwap.1.volume == 1)

        #expect(renderer.gains(for: outgoing, next: incoming, atFrame: frame(end) - 1).volume < 0.01)
        #expect(renderer.gains(for: incoming, next: nil, atFrame: frame(end + 1)) == MixGains())
    }

    @Test func seeksIntoTheMiddleOfATransition() throws {
        let (layout, sources) = try twoTrackSet(bpm: 126)
        let renderer = SetRenderer(layout: layout, sources: sources, config: playback)
        let bar = layout.entries[1].startBar + 2
        renderer.seek(toFrame: Int(Double(bar) * renderer.framesPerBar))
        let mix = render(renderer, frames: Int(4 * renderer.framesPerBar))
        let analysis = try TrackAnalyzer.analyze(samples: mix, needsKey: false, config: analysisConfig)
        let beat = 60 / 126.0
        var error = analysis.grid.firstDownbeat.truncatingRemainder(dividingBy: beat)
        if error > beat / 2 { error -= beat }
        #expect(abs(error) < 0.012)
    }
}

@Suite struct EqualizerTests {
    private func tone(_ frequency: Double, frames: Int, sampleRate: Double) -> [Float] {
        (0..<frames).map { Float(sin(2 * Double.pi * frequency * Double($0) / sampleRate)) }
    }

    private func process(_ input: [Float], gains: MixGains, sampleRate: Double) -> [Float] {
        var eq = DJEqualizer(sampleRate: sampleRate, maxFrames: input.count)
        var output = [Float](repeating: 0, count: input.count)
        input.withUnsafeBufferPointer { i in
            output.withUnsafeMutableBufferPointer { o in
                eq.process(i.baseAddress!, frames: input.count, from: gains, to: gains, addingInto: o.baseAddress!)
            }
        }
        return output
    }

    private func rms(_ x: ArraySlice<Float>) -> Float { (x.map { $0 * $0 }.reduce(0, +) / Float(x.count)).squareRoot() }

    /// Change in level, in dB, of a sine at `frequency` through the equalizer (after the filters settle).
    private func response(_ frequency: Double, gains: MixGains) -> Float {
        let output = process(tone(frequency, frames: 44_100, sampleRate: 44_100), gains: gains, sampleRate: 44_100)
        return 20 * log10(rms(output[22_050...]) / 0.7071)
    }

    @Test(arguments: [40.0, 250, 900, 2_500, 8_000])
    func unityGainsAreFlat(frequency: Double) {
        #expect(abs(response(frequency, gains: MixGains())) < 0.3)
    }

    @Test func killingTheLowsRemovesBassAndKeepsHighs() {
        let killed = MixGains(volume: 1, low: 0, mid: 1, high: 1)
        #expect(response(60, gains: killed) < -20)
        #expect(abs(response(6_000, gains: killed)) < 0.5)
    }
}
