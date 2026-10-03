import Foundation
import Testing
@testable import MADSETCore

@Suite struct StretchTests {
    private let config = AppConfig.current.analysis

    /// Kicks stretched from 124 to 128 BPM must land on the 128 BPM grid, at the start and still
    /// after a minute (no drift), when rendered block by block like the player does.
    @Test(arguments: [(from: 124.0, to: 128.0), (from: 130.0, to: 122.0)])
    func stretchedKicksStayOnTheTargetGrid(from: Double, to: Double) throws {
        let leadIn = 0.4
        let samples = Synth.track(bpm: from, bars: 40, leadIn: leadIn) { _ in [.kick, .bass, .hats] }
        let source = PCMBuffer(channels: [samples, samples], sampleRate: Synth.sampleRate)
        let stretcher = StretchedSource(source: source, ratio: from / to)
        stretcher.seek(toSourceFrame: Int(leadIn * Synth.sampleRate))

        let seconds = 60.0
        let total = Int(seconds * Synth.sampleRate)
        var left = [Float](repeating: 0, count: total)
        var right = [Float](repeating: 0, count: total)
        let block = 512
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                var offset = 0
                while offset < total {
                    let n = min(block, total - offset)
                    stretcher.render(into: [l.baseAddress! + offset, r.baseAddress! + offset], frames: n)
                    offset += n
                }
            }
        }

        let beat = 60 / to
        func phaseError(of segment: ArraySlice<Float>, startingAt start: Double) throws -> Double {
            let analysis = try TrackAnalyzer.analyze(samples: Array(segment), needsKey: false, config: config)
            #expect(abs(analysis.grid.bpm - to) < 0.02)
            var error = (analysis.grid.firstDownbeat + start).truncatingRemainder(dividingBy: beat)
            if error > beat / 2 { error -= beat }
            return error
        }
        let half = total / 2
        #expect(abs(try phaseError(of: left[0..<half], startingAt: 0)) < 0.012)
        #expect(abs(try phaseError(of: left[half...], startingAt: Double(half) / Synth.sampleRate)) < 0.012)
    }
}
