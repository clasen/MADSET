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

        try player.play()
        #expect(try pull(engine, seconds: 2) > 0.1)
        #expect(abs(player.currentTime - 2) < 0.05)

        player.pause()
        _ = try pull(engine, seconds: 0.5)
        #expect(abs(player.currentTime - 2) < 0.05)
    }

    @Test func seeksAndKeepsPositionAcrossTempoChanges() throws {
        let (player, engine, layout) = try makePlayer()
        try player.play()
        player.seek(to: 20)
        Thread.sleep(forTimeInterval: 0.2)
        #expect(try pull(engine, seconds: 1) > 0.1)
        // Playing waits for audio from the new place; pulled faster than real time, that wait spans a few blocks.
        #expect(player.currentTime <= 21 && player.currentTime > 20.85)

        // At 125 BPM, 21 s is bar 10.9375; at 140 BPM the same bar is 18.75 s in.
        let faster = SetLayout(bpm: 140, entries: [SetEntry(id: layout.entries[0].id, file: layout.entries[0].file)],
                               tracks: [layout.entries[0].id: .init(analysis: nil, duration: 60)], phraseBars: 8)
        let bar = player.currentTime / layout.barDuration
        player.load(faster)
        Thread.sleep(forTimeInterval: 0.2)
        _ = try pull(engine, seconds: 0.1)
        #expect(abs(player.currentTime / faster.barDuration - bar) < 0.1)
    }

    @Test func movingWhilePlayingGoesOnFromTheNextBarLineWithoutAGap() throws {
        let (player, engine, layout) = try makePlayer()
        try player.play()
        _ = try pull(engine, seconds: 1)
        let before = player.currentTime
        let target = layout.time(ofBar: 10)
        try player.move(to: target)
        #expect(abs((player.pendingMove ?? 0) - target) < 1 / sampleRate)

        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 1_024)!
        for _ in 0..<Int(2 * sampleRate / 512) {
            Thread.sleep(forTimeInterval: 0.002)
            #expect(try engine.renderOffline(512, to: buffer) == .success)
            #expect((0..<Int(buffer.frameLength)).contains { buffer.floatChannelData![0][$0] != 0 }, "A block went silent")
        }
        #expect(player.pendingMove == nil)
        // Two more seconds heard: on to the end of bar 0, then from bar 10 on.
        #expect(abs(player.currentTime - (target + before + 2 - layout.barDuration)) < 0.01)
    }

    @Test func movesByBarsAtTheNextBarLineAndAddsUpMovesBeforeIt() throws {
        let (player, engine, layout) = try makePlayer()
        try player.play()
        _ = try pull(engine, seconds: 1)
        let before = player.currentTime
        #expect(player.isSounding)
        player.move(byBars: 8)
        player.move(byBars: -2)
        Thread.sleep(forTimeInterval: 0.05)
        // Bar 1 is the next bar line; it goes on six bars past it, at bar 7.
        #expect(abs((player.pendingMove ?? 0) - layout.time(ofBar: 7)) < 1 / sampleRate)

        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 1_024)!
        for _ in 0..<Int(2 * sampleRate / 512) {
            Thread.sleep(forTimeInterval: 0.002)
            #expect(try engine.renderOffline(512, to: buffer) == .success)
            #expect((0..<Int(buffer.frameLength)).contains { buffer.floatChannelData![0][$0] != 0 }, "A block went silent")
        }
        #expect(player.pendingMove == nil)
        #expect(abs(player.currentTime - (before + 2 + layout.time(ofBar: 6))) < 0.01)
    }

    @Test func removingAPlayedTrackThatChangesTheTempoStaysOnWhatPlays() throws {
        var config = AppConfig.current.playback
        config.sampleRate = sampleRate
        let samples = Synth.track(bpm: 125, bars: 32, leadIn: 0.2) { _ in [.kick, .bass, .hats] }
        let analysis = try TrackAnalyzer.analyze(samples: samples, needsKey: false, config: AppConfig.current.analysis)
        let entries = (0..<3).map { _ in SetEntry(file: URL(filePath: "/synthetic/loop.wav")) }
        let tracks = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, SetLayout.TrackInfo(analysis: analysis, duration: analysis.duration)) })
        let layout = SetLayout(bpm: 125, entries: entries, tracks: tracks, phraseBars: 8)
        let sources = SourceCache(capacity: 1, sampleRate: sampleRate) { _, _ in PCMBuffer(channels: [samples, samples], sampleRate: Synth.sampleRate) }
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!, maximumFrameCount: 1_024)
        let player = try SetPlayer(config: config, sources: sources, engine: engine)
        player.load(layout)

        let third = layout.entries[2]
        try player.play(from: layout.time(ofBar: Double(third.startBar + third.overlapBars + 2)))
        _ = try pull(engine, seconds: 0.5)
        let trackBar = { (entry: PlacedEntry, layout: SetLayout, time: TimeInterval) in
            Double(entry.cueInBar) + layout.bar(atTime: time) - Double(entry.startBar)
        }
        let before = trackBar(third, layout, player.currentTime)

        let edited = SetLayout(bpm: 128, entries: [entries[0], entries[2]], tracks: tracks, phraseBars: 8)
        player.load(edited)
        Thread.sleep(forTimeInterval: 0.2)
        _ = try pull(engine, seconds: 0.5)
        // Half a second later at the new tempo, give or take the restart.
        let after = trackBar(edited.entries[1], edited, player.currentTime - 0.5)
        #expect(abs(after - before) < 0.1)
    }

    @Test func resumesAfterTheOutputDeviceChanges() throws {
        let (player, engine, _) = try makePlayer()
        try player.play()
        #expect(try pull(engine, seconds: 0.5) > 0.1)

        engine.stop()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        #expect(engine.isRunning)
        #expect(try pull(engine, seconds: 0.5) > 0.1)

        engine.stop()
        try player.play()
        #expect(engine.isRunning)
    }
}
