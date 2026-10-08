import Foundation
import Testing
@testable import MADSETCore

private let config = AppConfig.current.analysis

@Suite struct BeatGridTests {
    @Test(arguments: [(bpm: 126.0, leadIn: 0.31), (bpm: 140.0, leadIn: 0.05), (bpm: 92.5, leadIn: 1.2), (bpm: 84.0, leadIn: 0.6)])
    func findsTempoAndPhaseOfKicks(bpm: Double, leadIn: Double) throws {
        let samples = Synth.track(bpm: bpm, bars: 48, leadIn: leadIn) { _ in [.kick, .bass, .hats] }
        let analysis = try TrackAnalyzer.analyze(samples: samples, needsKey: false, config: config)

        #expect(abs(analysis.grid.bpm - bpm) < 0.01)
        let beat = 60 / bpm
        var phaseError = (analysis.grid.firstDownbeat - leadIn).truncatingRemainder(dividingBy: beat)
        if phaseError > beat / 2 { phaseError -= beat }
        if phaseError < -beat / 2 { phaseError += beat }
        #expect(abs(phaseError) < 0.012)
    }

    @Test func placesSlowlySwellingKicksAtTheirAttack() throws {
        let bpm = 122.0, leadIn = 0.4
        let samples = Synth.track(bpm: bpm, bars: 48, leadIn: leadIn) { _ in [.swellingKick, .hats] }
        let analysis = try TrackAnalyzer.analyze(samples: samples, needsKey: false, config: config)

        let beat = 60 / bpm
        var phaseError = (analysis.grid.firstDownbeat - leadIn).truncatingRemainder(dividingBy: beat)
        if phaseError > beat / 2 { phaseError -= beat }
        if phaseError < -beat / 2 { phaseError += beat }
        // The swell still drags the attack estimate later; the last step of it lies ~70 ms in.
        #expect(abs(phaseError) < 0.05)
    }

    @Test func silenceHasNoTempo() {
        let silence = [Float](repeating: 0, count: Int(30 * Synth.sampleRate))
        #expect(throws: BeatTracker.Failure.self) {
            try TrackAnalyzer.analyze(samples: silence, needsKey: false, config: config)
        }
    }
}

@Suite struct StructureTests {
    /// intro (kick + hats) · groove (+ bass) · breakdown (pad) · buildup (pad + riser) · drop (everything) · outro.
    @Test func labelsTheClassicArrangement() throws {
        let samples = Synth.track(bpm: 125, bars: 80, leadIn: 0.5) { bar in
            switch bar {
            case 0..<16: [.kick, .hats]
            case 16..<32: [.kick, .bass, .hats]
            case 32..<48: [.pad]
            case 48..<56: [.pad, .riser]
            case 56..<72: [.kick, .bass, .hats, .pad]
            default: [.kick, .hats]
            }
        }
        let analysis = try TrackAnalyzer.analyze(samples: samples, needsKey: false, config: config)

        #expect(abs(analysis.grid.firstDownbeat - 0.5) < 0.012)
        #expect(analysis.grid.phraseOffsetBars == 0)
        #expect(analysis.sections == [
            Section(phase: .intro, startBar: 0, endBar: 16),
            Section(phase: .groove, startBar: 16, endBar: 32),
            Section(phase: .breakdown, startBar: 32, endBar: 48),
            Section(phase: .buildup, startBar: 48, endBar: 56),
            Section(phase: .drop, startBar: 56, endBar: 72),
            Section(phase: .outro, startBar: 72, endBar: 80),
        ])
        #expect(analysis.kickPresence[0..<32].allSatisfy { $0 == 1 })
        #expect(analysis.kickPresence[32..<56].allSatisfy { $0 == 0 })
    }

    @Test func findsDownbeatAfterPickupBeats() throws {
        let beat = 60 / 124.0
        let leadIn = 0.2 + 3 * beat
        let samples = Synth.track(bpm: 124, bars: 48, leadIn: leadIn) { bar in
            bar % 16 < 8 ? [.kick, .hats] : [.kick, .bass, .hats, .pad]
        }
        let pickup = Synth.track(bpm: 124, bars: 1, leadIn: 0.2) { _ in [.kick] }
        var combined = samples
        for i in 0..<Int(3 * beat * Synth.sampleRate) { combined[Int(0.2 * Synth.sampleRate) + i] += pickup[Int(0.2 * Synth.sampleRate) + i] }

        let analysis = try TrackAnalyzer.analyze(samples: combined, needsKey: false, config: config)
        #expect(abs(analysis.grid.firstDownbeat - leadIn) < 0.012)
    }
}

@Suite struct KeyDetectorTests {
    @Test(arguments: [
        (notes: [110.0, 220.0, 261.63, 329.63], expected: "8A"),
        (notes: [130.81, 261.63, 329.63, 392.0], expected: "8B"),
        (notes: [98.0, 196.0, 233.08, 293.66], expected: "6A"),
    ])
    func detectsTriadKeys(notes: [Double], expected: String) {
        var x = [Float](repeating: 0, count: Int(20 * Synth.sampleRate))
        for note in notes { Synth.addTone(&x, at: 0, duration: 20, frequency: note, gain: 0.1, harmonics: 3) }
        #expect(KeyDetector.detect(x, sampleRate: Synth.sampleRate)?.description == expected)
    }
}

@Suite struct WaveformTests {
    @Test func coversTheWholeTrackAtTheConfiguredResolution() {
        let samples = Synth.track(bpm: 128, bars: 8) { _ in [.kick, .hats] }
        let bands = BandSignals(samples, sampleRate: Synth.sampleRate)
        let waveform = WaveformBuilder.build(bands, pointsPerSecond: 100)
        #expect(waveform.count == Int(bands.duration * 100))
        #expect(waveform.low.max() == 255)
    }
}

@Suite struct EnergyTests {
    @Test func quieterMixOfTheSameTrackRatesLower() throws {
        let loud = Synth.track(bpm: 126, bars: 32, leadIn: 0.2) { _ in [.kick, .bass, .hats, .pad] }
        let quiet = loud.map { $0 * 0.1 }
        let loudEnergy = try #require(try TrackAnalyzer.analyze(samples: loud, needsKey: false, config: config).detectedEnergy)
        let quietEnergy = try #require(try TrackAnalyzer.analyze(samples: quiet, needsKey: false, config: config).detectedEnergy)

        #expect((1...10).contains(loudEnergy) && (1...10).contains(quietEnergy))
        #expect(quietEnergy < loudEnergy)
    }
}
