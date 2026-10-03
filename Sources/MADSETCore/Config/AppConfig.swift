import Foundation

/// Single source of operational settings. Read as `AppConfig.current.<section>.<value>`.
public struct AppConfig: Sendable {
    public struct Analysis: Sendable {
        /// Mono sample rate every track is decoded to before analysis.
        public var sampleRate: Double
        /// How many tracks are decoded and analyzed at the same time.
        public var maxConcurrentTracks: Int
        /// Tempo search range. Electronic 4x4 material lives well inside it.
        public var minBPM: Double
        public var maxBPM: Double
        /// Bars per phrase; sections are aligned to this grid.
        public var phraseBars: Int
        /// Resolution of the stored overview waveform.
        public var waveformPointsPerSecond: Double
    }

    public struct Cache: Sendable {
        /// Folder inside ~/Library/Caches holding analysis results.
        public var folderName: String
    }

    public var analysis: Analysis
    public var cache: Cache

    public static let current = AppConfig(
        analysis: Analysis(
            sampleRate: 22_050,
            maxConcurrentTracks: 12,
            minBPM: 88,
            maxBPM: 175,
            phraseBars: 8,
            waveformPointsPerSecond: 100
        ),
        cache: Cache(folderName: "MADSET/analysis")
    )
}
