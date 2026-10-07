import Foundation

public enum TrackAnalyzer {
    /// Frame hop (in samples) of the kick onset envelope; ~2.9 ms at 22.05 kHz.
    static let onsetHop = 64

    public static func analyze(url: URL, needsKey: Bool, config: AppConfig.Analysis) throws -> TrackAnalysis {
        let samples = try AudioDecoder.decodeMono(url: url, sampleRate: config.sampleRate)
        return try analyze(samples: samples, needsKey: needsKey, config: config)
    }

    static func analyze(samples: [Float], needsKey: Bool, config: AppConfig.Analysis) throws -> TrackAnalysis {
        let bands = BandSignals(samples, sampleRate: config.sampleRate)
        let sub = OnsetEnvelope.amplitudeRise(of: bands.sub, sampleRate: config.sampleRate, hop: onsetHop)
        let attack = OnsetEnvelope.amplitudeRise(of: bands.low, sampleRate: config.sampleRate, hop: onsetHop)
        let tempo = try BeatTracker.estimate(sub: sub, attack: attack, minBPM: config.minBPM, maxBPM: config.maxBPM)
        let structure = StructureAnalyzer.analyze(bands, sub: sub, tempo: tempo, phraseBars: config.phraseBars)
        return TrackAnalysis(
            duration: bands.duration,
            grid: structure.grid,
            sections: structure.sections,
            kickPresence: structure.kickPresence,
            detectedKey: needsKey ? KeyDetector.detect(samples, sampleRate: config.sampleRate) : nil,
            detectedEnergy: EnergyEstimator.estimate(bands, grid: structure.grid, barCount: structure.kickPresence.count),
            waveform: WaveformBuilder.build(bands, pointsPerSecond: config.waveformPointsPerSecond)
        )
    }
}
