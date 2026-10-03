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

    public struct Playback: Sendable {
        /// Rate tracks are decoded and mixed at.
        public var sampleRate: Double
        /// Frames mixed per render call.
        public var blockFrames: Int
        /// Audio rendered ahead of the playhead; also the delay before an edit is heard.
        public var bufferSeconds: Double
        /// Tracks starting within this many seconds of the playhead are decoded in advance.
        public var prefetchSeconds: Double
        /// Decoded tracks kept in memory (~150 MB each for a 7-minute track).
        public var cachedSources: Int
        /// Tempo of a set before any of its tracks is analyzed.
        public var emptySetBPM: Double
    }

    public struct Export: Sendable {
        /// Sample depth of exported WAV files.
        public var wavBitDepth: Int
        /// Bits per second of exported AAC files.
        public var aacBitRate: Int
    }

    public struct Cache: Sendable {
        /// Folder inside ~/Library/Caches holding analysis results.
        public var folderName: String
    }

    public var analysis: Analysis
    public var playback: Playback
    public var export: Export
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
        playback: Playback(
            sampleRate: 44_100,
            blockFrames: 1_024,
            bufferSeconds: 0.35,
            prefetchSeconds: 45,
            cachedSources: 6,
            emptySetBPM: 124
        ),
        export: Export(wavBitDepth: 24, aacBitRate: 256_000),
        cache: Cache(folderName: "MADSET/analysis")
    )
}
