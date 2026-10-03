import Foundation

/// One track in the set as the user arranged it. Nil values are automatic: derived from the
/// analysis (phase-aligned) until the user edits them.
public struct SetEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var file: URL
    /// First bar of the track that plays (the track's own bar index).
    public var cueInBar: Int?
    /// Bar where the track stops (exclusive).
    public var cueOutBar: Int?
    /// Bars this track overlaps the previous one (its transition in). Ignored for the first entry.
    public var overlapBars: Int?
    /// Bar within the overlap where the lows swap from the previous track to this one.
    public var bassSwapBar: Int?

    public init(id: UUID = UUID(), file: URL, cueInBar: Int? = nil, cueOutBar: Int? = nil, overlapBars: Int? = nil, bassSwapBar: Int? = nil) {
        self.id = id
        self.file = file
        self.cueInBar = cueInBar
        self.cueOutBar = cueOutBar
        self.overlapBars = overlapBars
        self.bassSwapBar = bassSwapBar
    }
}

/// An entry resolved onto the set's bar axis at the global tempo.
public struct PlacedEntry: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let file: URL
    /// Set bar where the entry starts.
    public let startBar: Int
    public let cueInBar: Int
    public let cueOutBar: Int
    /// Bars overlapping the previous entry, and where the lows swap within them.
    public let overlapBars: Int
    public let bassSwapBar: Int
    /// The track's own grid; nil while the track is not analyzed (it then has no audio in the set).
    public let grid: BeatGrid?

    public init(id: UUID, file: URL, startBar: Int, cueInBar: Int, cueOutBar: Int, overlapBars: Int, bassSwapBar: Int, grid: BeatGrid?) {
        self.id = id
        self.file = file
        self.startBar = startBar
        self.cueInBar = cueInBar
        self.cueOutBar = cueOutBar
        self.overlapBars = overlapBars
        self.bassSwapBar = bassSwapBar
        self.grid = grid
    }

    public var lengthBars: Int { cueOutBar - cueInBar }
    public var endBar: Int { startBar + lengthBars }
}

/// Tempo-aligned layout of the set: every entry is stretched to `bpm` and placed on whole bars.
public struct SetLayout: Sendable, Equatable {
    public let bpm: Double
    public let entries: [PlacedEntry]

    public var barDuration: TimeInterval { 240 / bpm }
    public var totalBars: Int { entries.map(\.endBar).max() ?? 0 }
    public var duration: TimeInterval { Double(totalBars) * barDuration }

    public func time(ofBar bar: Double) -> TimeInterval { bar * barDuration }
    public func bar(atTime time: TimeInterval) -> Double { time / barDuration }

    /// What the planner needs to know about a track.
    public struct TrackInfo: Sendable {
        public let analysis: TrackAnalysis?
        /// Header duration, used to size tracks that are not analyzed yet.
        public let duration: TimeInterval?

        public init(analysis: TrackAnalysis?, duration: TimeInterval?) {
            self.analysis = analysis
            self.duration = duration
        }
    }

    public init(bpm: Double, entries: [SetEntry], tracks: [UUID: TrackInfo], phraseBars: Int) {
        precondition(bpm > 0, "Set tempo must be positive")
        self.bpm = bpm
        var placed: [PlacedEntry] = []
        for entry in entries {
            guard let info = tracks[entry.id] else { preconditionFailure("No track info for entry \(entry.id)") }
            let cueIn = entry.cueInBar ?? TransitionPlanner.automaticCueIn(info.analysis)
            let barCount = info.analysis.map(TransitionPlanner.barCount) ?? Int((info.duration ?? 0) / (240 / bpm))
            let cueOut = max(cueIn + 1, min(barCount, entry.cueOutBar ?? TransitionPlanner.automaticCueOut(info.analysis, barCount: barCount, phraseBars: phraseBars)))

            var overlap = 0
            var swap = 0
            var start = 0
            if let previous = placed.last {
                let previousInfo = tracks[previous.id]
                let automatic = TransitionPlanner.automaticOverlap(
                    outgoing: previousInfo?.analysis, outgoingCueOut: previous.cueOutBar,
                    incoming: info.analysis, incomingCueIn: cueIn, phraseBars: phraseBars
                )
                let longest = min(previous.lengthBars, cueOut - cueIn) - 1
                overlap = max(0, min(entry.overlapBars ?? automatic, longest))
                swap = min(max(0, entry.bassSwapBar ?? overlap / 2), overlap)
                start = previous.endBar - overlap
            }
            placed.append(PlacedEntry(
                id: entry.id, file: entry.file, startBar: start, cueInBar: cueIn, cueOutBar: cueOut,
                overlapBars: overlap, bassSwapBar: swap, grid: info.analysis?.grid
            ))
        }
        self.entries = placed
    }

    /// A tempo for the whole set: the median of the analyzed tracks, to the nearest half BPM.
    public static func suggestedBPM(_ tempos: [Double]) -> Double? {
        guard !tempos.isEmpty else { return nil }
        let sorted = tempos.sorted()
        return (sorted[sorted.count / 2] * 2).rounded() / 2
    }
}

/// Phase-aware defaults for cue points and transitions.
public enum TransitionPlanner {
    /// Automatic overlaps span this many phrases at least and at most: shorter mixes sound abrupt,
    /// longer ones are rare in a DJ set.
    static let minimumOverlapPhrases = 2
    static let maximumOverlapBars = 32

    public static func barCount(_ analysis: TrackAnalysis) -> Int {
        max(1, Int((analysis.duration - analysis.grid.firstDownbeat) / analysis.grid.barDuration))
    }

    /// Start at the first phrase boundary.
    static func automaticCueIn(_ analysis: TrackAnalysis?) -> Int {
        analysis?.grid.phraseOffsetBars ?? 0
    }

    /// Stop at the last phrase boundary, so the outgoing track's tail is phrase-aligned.
    static func automaticCueOut(_ analysis: TrackAnalysis?, barCount: Int, phraseBars: Int) -> Int {
        guard let analysis else { return barCount }
        let offset = analysis.grid.phraseOffsetBars
        let lastBoundary = offset + (barCount - offset) / phraseBars * phraseBars
        return lastBoundary > offset ? lastBoundary : barCount
    }

    /// Overlap the outgoing outro with the incoming intro, in whole phrases.
    static func automaticOverlap(outgoing: TrackAnalysis?, outgoingCueOut: Int, incoming: TrackAnalysis?, incomingCueIn: Int, phraseBars: Int) -> Int {
        let outro = outgoing.flatMap { analysis -> Int? in
            guard let last = analysis.sections.last, last.phase == .outro else { return nil }
            return max(0, min(outgoingCueOut, last.endBar) - last.startBar)
        }
        let intro = incoming.flatMap { analysis -> Int? in
            guard let first = analysis.sections.first, first.phase == .intro else { return nil }
            return max(0, first.endBar - max(incomingCueIn, first.startBar))
        }
        let candidate: Int
        switch (outro, intro) {
        case let (outro?, intro?): candidate = min(outro, intro)
        case let (single?, nil), let (nil, single?): candidate = single
        case (nil, nil): candidate = 2 * phraseBars
        }
        let phrases = min(candidate, maximumOverlapBars) / phraseBars
        return max(minimumOverlapPhrases, phrases) * phraseBars
    }
}
