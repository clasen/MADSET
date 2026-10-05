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

    public struct Sync: Sendable {
        /// Seconds ahead MIDI clock is scheduled: longer rides out a busy system, shorter follows a seek sooner.
        public var clockLookahead: Double
        /// Seconds between the MIDI clock thread's looks at the playhead.
        public var clockPollInterval: Double
        /// Largest delay or advance, in seconds, the MIDI clock offset setting allows.
        public var maxOffset: Double
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

    public struct Library: Sendable {
        /// Folder inside ~/Music holding the sets; its folders are the groups.
        public var folderName: String
        /// Seconds file changes in the sets folder are gathered before the sidebar reloads.
        public var watchLatency: Double
        /// Seconds a set waits after a change before saving it, so a burst of edits writes once.
        public var saveDelay: Double
    }

    public struct Ordering: Sendable {
        /// Where the set curve peaks, as a fraction of the way through the ordered tracks.
        public var peakPosition: Double
    }

    public var analysis: Analysis
    public var playback: Playback
    public var sync: Sync
    public var export: Export
    public var cache: Cache
    public var library: Library
    public var ordering: Ordering

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
        sync: Sync(clockLookahead: 0.03, clockPollInterval: 0.005, maxOffset: 0.15),
        export: Export(wavBitDepth: 24, aacBitRate: 256_000),
        cache: Cache(folderName: "MADSET/analysis"),
        library: Library(folderName: "MADSET", watchLatency: 0.3, saveDelay: 1),
        ordering: Ordering(peakPosition: 0.7)
    )
}
