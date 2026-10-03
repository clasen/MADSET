import AVFoundation
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

    /// The second part of a split track plays as the whole track would after a seek to the cut.
    @Test func aSplitTrackPlaysOnFromTheCut() throws {
        let (whole, sources) = try twoTrackSet(bpm: 126)
        let file = whole.entries[0].file
        let analysis = try TrackAnalyzer.analyze(samples: try sources.buffer(for: file).channels[0], needsKey: false, config: analysisConfig)
        let info = SetLayout.TrackInfo(analysis: analysis, duration: analysis.duration)
        var first = SetEntry(file: file)
        let second = first.split(atBar: 16)
        let single = SetLayout(bpm: 126, entries: [SetEntry(id: first.id, file: file)], tracks: [first.id: info], phraseBars: 8)
        let split = SetLayout(bpm: 126, entries: [first, second], tracks: [first.id: info, second.id: info], phraseBars: 8)
        #expect(split.totalBars == single.totalBars)

        let reference = SetRenderer(layout: single, sources: sources, config: playback)
        let frames = Int(8 * reference.framesPerBar)
        let cut = Int(Double(split.entries[1].startBar) * reference.framesPerBar)
        reference.seek(toFrame: cut - frames / 2)
        let renderer = SetRenderer(layout: split, sources: sources, config: playback)
        renderer.seek(toFrame: cut - frames / 2)
        let played = render(renderer, frames: frames)
        #expect(Array(played[..<(frames / 2)]) == render(reference, frames: frames / 2))
        reference.seek(toFrame: cut)
        #expect(Array(played[(frames / 2)...]) == render(reference, frames: frames - frames / 2))
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

    /// A temporary file named the way the save panel names it: with the format's preferred extension.
    private func exportURL(_ format: SetExporter.Format) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "madset-export-\(UUID().uuidString)")
            .appendingPathExtension(for: format.contentType)
    }

    @Test func exportsTheSameMixThePlayerPlays() throws {
        let (layout, sources) = try twoTrackSet(bpm: 126)
        let url = exportURL(.wav)
        defer { try? FileManager.default.removeItem(at: url) }
        var reported: [Double] = []
        try SetExporter.export(layout, format: .wav, to: url, sources: sources, playback: playback,
                               config: AppConfig.current.export) { reported.append($0) }

        let expected = render(SetRenderer(layout: layout, sources: sources, config: playback), frames: Int((layout.duration * playback.sampleRate).rounded()))
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == playback.sampleRate && file.fileFormat.channelCount == 2)
        #expect(Int(file.length) == expected.count)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let left = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        #expect(zip(left, expected).allSatisfy { abs($0 - $1) < 1e-5 })
        #expect(reported.last == 1 && zip(reported, reported.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func exportsAAC() throws {
        let (layout, sources) = try twoTrackSet(bpm: 126)
        let url = exportURL(.aac)
        defer { try? FileManager.default.removeItem(at: url) }
        // The synthetic tracks run at 22.05 kHz, where AAC tops out below the app's bit rate.
        var export = AppConfig.current.export
        export.aacBitRate = 96_000
        try SetExporter.export(layout, format: .aac, to: url, sources: sources, playback: playback, config: export) { _ in }
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
        #expect(abs(Double(file.length) / file.fileFormat.sampleRate - layout.duration) < 0.1)
    }

    @Test func cancelledExportLeavesNoFile() throws {
        let (layout, sources) = try twoTrackSet(bpm: 126)
        let url = exportURL(.wav)
        #expect(throws: CancellationError.self) {
            try SetExporter.export(layout, format: .wav, to: url, sources: sources, playback: playback,
                                   config: AppConfig.current.export) { if $0 > 0.5 { throw CancellationError() } }
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
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

@Suite struct TransitionCurvesTests {
    private func placed(startBar: Int, overlap: Int, fadeIn: Int, fadeOut: Int) -> PlacedEntry {
        PlacedEntry(
            id: UUID(), file: URL(filePath: "/x.mp3"), startBar: startBar, cueInBar: 0, cueOutBar: 64,
            overlapBars: overlap, bassSwapBar: overlap / 2, fadeInBars: fadeIn, fadeOutBars: fadeOut, barCount: 64, grid: nil
        )
    }

    @Test func fadesOverTheEditedBars() {
        let outgoing = placed(startBar: 0, overlap: 0, fadeIn: 0, fadeOut: 0)
        let incoming = placed(startBar: 48, overlap: 16, fadeIn: 8, fadeOut: 12)
        let volume = { (entry: PlacedEntry, next: PlacedEntry?, bar: Double) in TransitionCurves.levels(for: entry, next: next, atBar: bar).volume }

        #expect(volume(incoming, nil, 48) == 0)
        #expect(abs(volume(incoming, nil, 52) - Float(sin(Double.pi / 4))) < 1e-6)
        #expect(volume(incoming, nil, 56) == 1)

        #expect(volume(outgoing, incoming, 52) == 1)  // the fade out starts 12 bars before the end of the overlap
        #expect(abs(volume(outgoing, incoming, 58) - Float(cos(Double.pi / 4))) < 1e-6)
        #expect(volume(outgoing, incoming, 63.99) < 0.01)
    }

    @Test func aFadeOfNoBarsCuts() {
        let outgoing = placed(startBar: 0, overlap: 0, fadeIn: 0, fadeOut: 0)
        let incoming = placed(startBar: 48, overlap: 16, fadeIn: 0, fadeOut: 0)
        #expect(TransitionCurves.levels(for: incoming, next: nil, atBar: 48).volume == 1)
        #expect(TransitionCurves.levels(for: outgoing, next: incoming, atBar: 63.99).volume == 1)
    }
}
