import Foundation

/// Metadata read from the file's tags (Mixed In Key writes key and energy there).
public struct TrackTags: Codable, Sendable, Equatable {
    public var title: String?
    public var artist: String?
    public var key: CamelotKey?
    public var energy: Int?
    public var bpm: Double?

    public init(title: String? = nil, artist: String? = nil, key: CamelotKey? = nil, energy: Int? = nil, bpm: Double? = nil) {
        self.title = title
        self.artist = artist
        self.key = key
        self.energy = energy
        self.bpm = bpm
    }
}

/// Constant-tempo grid. Bar `n` starts at `firstDownbeat + n * barDuration`.
public struct BeatGrid: Codable, Sendable, Equatable {
    public var bpm: Double
    /// Time of the first downbeat at or after the start of the file.
    public var firstDownbeat: TimeInterval
    /// Bar index (0..<phraseBars) at which phrases start.
    public var phraseOffsetBars: Int
    /// Fraction (0...1) of the kick energy explained by the grid; low values mean an unreliable grid.
    public var confidence: Double

    public init(bpm: Double, firstDownbeat: TimeInterval, phraseOffsetBars: Int, confidence: Double) {
        self.bpm = bpm
        self.firstDownbeat = firstDownbeat
        self.phraseOffsetBars = phraseOffsetBars
        self.confidence = confidence
    }

    public var beatDuration: TimeInterval { 60 / bpm }
    public var barDuration: TimeInterval { 4 * beatDuration }

    public func barStart(_ bar: Int) -> TimeInterval {
        firstDownbeat + Double(bar) * barDuration
    }
}

/// Phase of a track in DJ terms.
public enum Phase: String, Codable, Sendable, CaseIterable {
    case intro, groove, buildup, drop, breakdown, outro
}

/// A run of whole bars sharing one phase. `endBar` is exclusive.
public struct Section: Codable, Sendable, Equatable {
    public var phase: Phase
    public var startBar: Int
    public var endBar: Int

    public init(phase: Phase, startBar: Int, endBar: Int) {
        precondition(endBar > startBar, "Empty section \(phase) \(startBar)..<\(endBar)")
        self.phase = phase
        self.startBar = startBar
        self.endBar = endBar
    }
}

/// Three-band peak envelope used to draw the waveform, one byte per point and band.
public struct Waveform: Codable, Sendable, Equatable {
    public var pointsPerSecond: Double
    public var low: Data
    public var mid: Data
    public var high: Data

    public init(pointsPerSecond: Double, low: Data, mid: Data, high: Data) {
        precondition(low.count == mid.count && mid.count == high.count, "Waveform bands differ in length")
        self.pointsPerSecond = pointsPerSecond
        self.low = low
        self.mid = mid
        self.high = high
    }

    public var count: Int { low.count }
}

public struct TrackAnalysis: Codable, Sendable, Equatable {
    public var duration: TimeInterval
    public var grid: BeatGrid
    public var sections: [Section]
    /// Kick presence per bar (0...1), indexed like the grid's bars.
    public var kickPresence: [Float]
    /// Key estimated from audio. Only computed when the tags carry none.
    public var detectedKey: CamelotKey?
    public var waveform: Waveform

    public init(duration: TimeInterval, grid: BeatGrid, sections: [Section], kickPresence: [Float], detectedKey: CamelotKey?, waveform: Waveform) {
        self.duration = duration
        self.grid = grid
        self.sections = sections
        self.kickPresence = kickPresence
        self.detectedKey = detectedKey
        self.waveform = waveform
    }
}
