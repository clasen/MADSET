import AVFoundation
import Foundation
import Testing
@testable import MADSETCore

/// Drives the player through an engine in offline manual-rendering mode: no sound device involved.
@Suite(.serialized) struct PlayerTests {
    private let sampleRate = Synth.sampleRate

    private func makePlayer() throws -> (SetPlayer, AVAudioEngine, SetLayout) {
        var config = AppConfig.current.playback
        config.sampleRate = sampleRate
        let samples = Synth.track(bpm: 125, bars: 32, leadIn: 0.2) { _ in [.kick, .bass, .hats] }
        let entry = SetEntry(file: URL(filePath: "/synthetic/loop.wav"))
        let analysis = try TrackAnalyzer.analyze(samples: samples, needsKey: false, config: AppConfig.current.analysis)
        let layout = SetLayout(bpm: 125, entries: [entry], tracks: [entry.id: .init(analysis: analysis, duration: analysis.duration)], phraseBars: 8)
        let sources = SourceCache(capacity: 1, sampleRate: sampleRate) { _, _ in PCMBuffer(channels: [samples, samples], sampleRate: Synth.sampleRate) }

        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!, maximumFrameCount: 1_024)
        let player = try SetPlayer(config: config, sources: sources, engine: engine)
        player.load(layout)
        return (player, engine, layout)
    }

    /// Pulls `seconds` of output in small steps, giving the producer time to stay ahead. Returns the peak level.
    private func pull(_ engine: AVAudioEngine, seconds: Double) throws -> Float {
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 1_024)!
        var peak: Float = 0
        for _ in 0..<Int(seconds * sampleRate / 512) {
            Thread.sleep(forTimeInterval: 0.002)
            #expect(try engine.renderOffline(512, to: buffer) == .success)
            for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(buffer.floatChannelData![0][i])) }
        }
        return peak
    }

    @Test func playsPausesAndTracksThePlayhead() throws {
        let (player, engine, _) = try makePlayer()
        Thread.sleep(forTimeInterval: 0.2)
        #expect(try pull(engine, seconds: 0.5) == 0)
        #expect(player.currentTime == 0)

        player.play()
        #expect(try pull(engine, seconds: 2) > 0.1)
        #expect(abs(player.currentTime - 2) < 0.05)

        player.pause()
        _ = try pull(engine, seconds: 0.5)
        #expect(abs(player.currentTime - 2) < 0.05)
    }

    @Test func seeksAndKeepsPositionAcrossTempoChanges() throws {
        let (player, engine, layout) = try makePlayer()
        player.play()
        player.seek(to: 20)
        Thread.sleep(forTimeInterval: 0.2)
        #expect(try pull(engine, seconds: 1) > 0.1)
        #expect(abs(player.currentTime - 21) < 0.05)

        // At 125 BPM, 21 s is bar 10.9375; at 140 BPM the same bar is 18.75 s in.
        let faster = SetLayout(bpm: 140, entries: [SetEntry(id: layout.entries[0].id, file: layout.entries[0].file)],
                               tracks: [layout.entries[0].id: .init(analysis: nil, duration: 60)], phraseBars: 8)
        let bar = player.currentTime / layout.barDuration
        player.load(faster)
        Thread.sleep(forTimeInterval: 0.2)
        _ = try pull(engine, seconds: 0.1)
        #expect(abs(player.currentTime / faster.barDuration - bar) < 0.1)
    }
}
