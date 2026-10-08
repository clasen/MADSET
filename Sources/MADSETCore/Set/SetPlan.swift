import Foundation

/// One track in the set as the user arranged it. Nil values are automatic: derived from the
/// analysis (phase-aligned) until the user edits them.
public struct SetEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var file: URL
    /// First bar of the track that plays (the track's own bar index). Negative bars are silence
    /// before the track's audio, allowed inside its transition in.
    public var cueInBar: Int?
    /// Bar where the track stops (exclusive). Bars past the track's audio are silence, allowed inside
    /// its transition out.
    public var cueOutBar: Int?
    /// Bars this track overlaps the previous one (its transition in). Ignored for the first entry.
    public var overlapBars: Int?
    /// Bar within the overlap where the lows swap from the previous track to this one.
    public var bassSwapBar: Int?
    /// Bars this track takes to fade in, from the start of the overlap.
    public var fadeInBars: Int?
    /// Bars the previous track takes to fade out, ending with the overlap.
    public var fadeOutBars: Int?

    public init(
        id: UUID = UUID(), file: URL, cueInBar: Int? = nil, cueOutBar: Int? = nil, overlapBars: Int? = nil, bassSwapBar: Int? = nil,
        fadeInBars: Int? = nil, fadeOutBars: Int? = nil
    ) {
        self.id = id
        self.file = file
        self.cueInBar = cueInBar
        self.cueOutBar = cueOutBar
        self.overlapBars = overlapBars
        self.bassSwapBar = bassSwapBar
        self.fadeInBars = fadeInBars
        self.fadeOutBars = fadeOutBars
    }

    /// Splits the entry at one of its track's bars: this entry now ends there, and the returned one,
    /// a new entry for the same file, plays from there to where this one ended. From then on they
    /// arrange like two tracks; placed one after the other they join seamlessly (see `SetLayout`).
    public mutating func split(atBar bar: Int) -> SetEntry {
        let second = SetEntry(file: file, cueInBar: bar, cueOutBar: cueOutBar)
        cueOutBar = bar
        return second
    }

    /// Returns the transition from the previous track to automatic, for when that track changes.
    public mutating func resetTransitionIn() {
        overlapBars = nil
        bassSwapBar = nil
        fadeInBars = nil
        fadeOutBars = nil
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
    /// Bars of the overlap this entry fades in over (from its start) and the previous one fades out over (to its end).
    public let fadeInBars: Int
    public let fadeOutBars: Int
    /// Whole bars in the track's audio.
    public let barCount: Int
    /// The track's own grid; nil while the track is not analyzed (it then has no audio in the set).
    public let grid: BeatGrid?

    public init(
        id: UUID, file: URL, startBar: Int, cueInBar: Int, cueOutBar: Int, overlapBars: Int, bassSwapBar: Int,
        fadeInBars: Int, fadeOutBars: Int, barCount: Int, grid: BeatGrid?
    ) {
        self.id = id
        self.file = file
        self.startBar = startBar
        self.cueInBar = cueInBar
        self.cueOutBar = cueOutBar
        self.overlapBars = overlapBars
        self.bassSwapBar = bassSwapBar
        self.fadeInBars = fadeInBars
        self.fadeOutBars = fadeOutBars
        self.barCount = barCount
        self.grid = grid
    }

    public var lengthBars: Int { cueOutBar - cueInBar }
    public var endBar: Int { startBar + lengthBars }

    /// Bar of the set where the track's own bar 0 falls; each set bar plays the track's bar that far in.
    public var trackOrigin: Int { startBar - cueInBar }

    /// Track bars where `SetEntry.split(atBar:)` leaves the set sounding the same: the first part
    /// keeps the transition in, the second the transition into `next`, and each a bar of its own.
    /// Nil when the entry is too short.
    public func splitRange(before next: PlacedEntry?) -> ClosedRange<Int>? {
        let earliest = cueInBar + overlapBars + 1
        let latest = cueOutBar - (next?.overlapBars ?? 0) - 1
        return earliest <= latest ? earliest...latest : nil
    }

    /// Bar of the previous track (its own bar index) where this entry starts to play over it.
    public func mixInBar(after previous: PlacedEntry) -> Int { previous.cueOutBar - overlapBars }

    /// Bar of this track (its own index) where a transition out can start at the earliest: after its
    /// transition in and a bar of its own, so no more than two tracks play at once.
    var earliestMixOutBar: Int { cueInBar + overlapBars + 1 }

    /// Where the transition from `previous` can start while keeping its length: the previous track
    /// keeps at least one bar of its own before it and cannot play past its last bar.
    public func mixInRange(after previous: PlacedEntry) -> ClosedRange<Int> {
        let earliest = previous.earliestMixOutBar
        return earliest...max(earliest, previous.barCount - overlapBars)
    }

    /// The cue out `previous` needs for this entry to start at `bar` of it with the same transition length.
    public func previousCueOut(mixingInAt bar: Int, after previous: PlacedEntry) -> Int {
        bar.clamped(to: mixInRange(after: previous)) + overlapBars
    }

    /// Bars of the transition from `previous` that are silence for one of its tracks: past the
    /// previous track's audio, and before this one's.
    public func transitionSilence(after previous: PlacedEntry) -> (outgoing: Int, incoming: Int) {
        (max(0, previous.cueOutBar - previous.barCount), max(0, -cueInBar))
    }

    /// Makes the transition from `previous` `length` bars long without moving either track's audio
    /// or the bass swap: the previous track ends later and this one starts earlier (or the reverse),
    /// half on each side, the rest on whichever side has room. See `trimmingStart` and `trimmingEnd`
    /// for the limits.
    public func resizingTransition(to length: Int, after previous: PlacedEntry) -> (previousCueOut: Int, cueIn: Int, overlap: Int, bassSwap: Int) {
        var outgoing = previous
        var incoming = self
        func trimEnd(by bars: Int) {
            // Short of taking the incoming track along.
            let shortening = min(0, incoming.shortestOverlap(after: outgoing) - incoming.overlapBars)
            let trimmed = outgoing.trimmingEnd(by: max(bars, shortening), before: incoming)
            outgoing = outgoing.with(cueOut: trimmed.cueOut)
            incoming = incoming.with(overlap: trimmed.nextOverlap!, bassSwap: trimmed.nextBassSwap!)
        }
        func growStart(by bars: Int) {
            let trimmed = incoming.trimmingStart(by: -bars, after: outgoing)
            incoming = incoming.with(cueIn: trimmed.cueIn, overlap: trimmed.overlap, bassSwap: trimmed.bassSwap)
        }
        let target = max(0, length)
        trimEnd(by: (target - overlapBars) / 2)
        growStart(by: target - incoming.overlapBars)
        trimEnd(by: target - incoming.overlapBars)
        return (outgoing.cueOutBar, incoming.cueInBar, incoming.overlapBars, incoming.bassSwapBar)
    }

    /// The lengths `resizingTransition(to:after:)` can reach.
    public func transitionLengths(after previous: PlacedEntry) -> ClosedRange<Int> {
        resizingTransition(to: 0, after: previous).overlap...resizingTransition(to: previous.lengthBars + lengthBars, after: previous).overlap
    }

    /// A copy with some values changed; the start moves with the cue in, the end stays.
    private func with(cueIn: Int? = nil, cueOut: Int? = nil, overlap: Int? = nil, bassSwap: Int? = nil) -> PlacedEntry {
        let cueIn = cueIn ?? cueInBar
        return PlacedEntry(
            id: id, file: file, startBar: startBar + cueIn - cueInBar, cueInBar: cueIn, cueOutBar: cueOut ?? cueOutBar,
            overlapBars: overlap ?? overlapBars, bassSwapBar: bassSwap ?? bassSwapBar, fadeInBars: fadeInBars, fadeOutBars: fadeOutBars,
            barCount: barCount, grid: grid
        )
    }

    /// Bars of silence the transition may hold in all, keeping a bar of audio of each track.
    private var silenceLimit: Int { max(0, overlapBars - 1) }

    /// Moves this track `bars` later in the set while its transition in from `previous` stays where
    /// it is: a different part of the track plays under it. Moved later than its first bar, the
    /// track starts later instead and the transition gets that much shorter (see `trimmingStart`),
    /// rather than opening silence before it. Keeps at least one bar of the track after the transition.
    /// Without a transition in, moved earlier the track plays over the end of `previous` instead,
    /// which opens one with the bass swap in its middle; it holds a bar of the previous track's
    /// audio, which keeps a bar of its own before it.
    public func sliding(by bars: Int, after previous: PlacedEntry) -> (cueIn: Int, overlap: Int, bassSwap: Int) {
        if overlapBars == 0, bars < 0 {
            let overlap = openingTransition(to: -bars, after: previous)
            return (cueInBar, overlap, overlap / 2)
        }
        let latest = max(cueInBar, cueOutBar - 1 - overlapBars)
        let cueIn = (cueInBar - bars).clamped(to: min(cueInBar, 0)...latest)
        let shortened = trimmingStart(by: max(0, cueIn - (cueInBar - bars)), after: previous)
        return (cueIn, shortened.overlap, shortened.bassSwap)
    }

    /// How long the transition from `previous` gets when this track plays `length` bars over its end,
    /// both keeping their cues: it holds a bar of the previous track's audio, which keeps a bar of its
    /// own before it, and this track keeps a bar of its own. Never shorter than it is.
    private func openingTransition(to length: Int, after previous: PlacedEntry) -> Int {
        let outgoingSilence = max(0, previous.cueOutBar - previous.barCount)
        let longest = min(previous.cueOutBar - previous.earliestMixOutBar, lengthBars - 1)
        guard longest > outgoingSilence else { return overlapBars }
        return max(length, outgoingSilence + 1).clamped(to: overlapBars...max(overlapBars, longest))
    }

    /// Starts this track `bars` later without moving its audio, the previous track's end or the bass
    /// swap: the transition from `previous` gets that much shorter. It can grow back through the
    /// track's audio, but not into silence before it, and leaves the previous track a bar of its own.
    public func trimmingStart(by bars: Int, after previous: PlacedEntry) -> (cueIn: Int, overlap: Int, bassSwap: Int) {
        let outgoingSilence = transitionSilence(after: previous).outgoing
        let earliest = min(0, max(overlapBars - (previous.cueOutBar - previous.earliestMixOutBar), cueInBar >= 0 ? -cueInBar : 0))
        let latest = max(0, overlapBars - (outgoingSilence > 0 ? outgoingSilence + 1 : 0))
        let shift = bars.clamped(to: earliest...latest)
        let overlap = overlapBars - shift
        return (cueInBar + shift, overlap, (bassSwapBar - shift).clamped(to: 0...overlap))
    }

    /// Where dragging this track's leading edge `bars` later leaves it: `trimmingStart` while the
    /// transition from `previous` can get shorter. Past the shortest transition the track starts
    /// further into itself and takes the rest of the set along, keeping a bar of its own before the
    /// transition into `next`. Without a transition, dragged earlier, it opens one (see `sliding`).
    public func trimmingLeadingEdge(by bars: Int, after previous: PlacedEntry, before next: PlacedEntry?) -> (cueIn: Int, overlap: Int, bassSwap: Int) {
        if overlapBars == 0, bars < 0 { return sliding(by: bars, after: previous) }
        let trimmed = trimmingStart(by: bars, after: previous)
        let rest = bars - (trimmed.cueIn - cueInBar)
        guard rest > 0 else { return trimmed }
        let latest = cueOutBar - 1 - trimmed.overlap - (next?.overlapBars ?? 0)
        return (max(trimmed.cueIn, min(trimmed.cueIn + rest, latest)), trimmed.overlap, trimmed.bassSwap)
    }

    /// The cue in that starts the first track of the set `bars` later into itself: the rest of the
    /// set moves along with its end. With no transition in to hide it, it never reaches into silence
    /// before the track's audio; it keeps a bar of its own before the transition into `next`.
    public func firstCueIn(trimmedBy bars: Int, before next: PlacedEntry?) -> Int {
        let earliest = min(0, -cueInBar)
        let latest = max(0, lengthBars - 1 - (next?.overlapBars ?? 0))
        return cueInBar + bars.clamped(to: earliest...latest)
    }

    /// Ends this track `bars` later without moving its audio, the next track or its bass swap: the
    /// transition into `next` gets that much longer. It can shrink back through silence past the
    /// track's audio but not grow into more of it. Shortened past the shortest transition, the track
    /// takes `next`, and the rest of the set, along. Each track keeps a bar of its own, and the
    /// transition keeps a bar of the next track's audio.
    public func trimmingEnd(by bars: Int, before next: PlacedEntry?) -> (cueOut: Int, nextOverlap: Int?, nextBassSwap: Int?) {
        let shortest = next.map { min($0.overlapBars, $0.shortestOverlap(after: self)) } ?? 0
        let earliest = overlapBars + 1 + shortest - lengthBars
        var latest = max(cueOutBar, barCount) - cueOutBar
        if let next { latest = min(latest, next.lengthBars - 1 - next.overlapBars) }
        let shift = bars.clamped(to: min(0, earliest)...max(0, latest))
        guard let next else { return (cueOutBar + shift, nil, nil) }
        let overlap = max(shortest, next.overlapBars + shift)
        return (cueOutBar + shift, overlap, next.bassSwapBar.clamped(to: 0...overlap))
    }

    /// Where dragging this track's trailing edge `bars` later leaves it and `next`: `trimmingEnd`.
    /// Without a transition into `next`, dragged past the end of the track's audio, it opens one by
    /// bringing `next`, and the rest of the set, over the track's end instead.
    public func trimmingTrailingEdge(by bars: Int, before next: PlacedEntry?) -> (cueOut: Int, nextOverlap: Int?, nextBassSwap: Int?) {
        let trimmed = trimmingEnd(by: bars, before: next)
        let rest = bars - (trimmed.cueOut - cueOutBar)
        guard let next, next.overlapBars == 0, let extended = trimmed.nextOverlap, rest > 0 else { return trimmed }
        let overlap = next.with(overlap: extended).openingTransition(to: extended + rest, after: with(cueOut: trimmed.cueOut))
        return (trimmed.cueOut, overlap, overlap / 2)
    }

    /// The shortest transition from `previous`: one bar of this track's audio past its silence.
    func shortestOverlap(after previous: PlacedEntry) -> Int {
        let incomingSilence = transitionSilence(after: previous).incoming
        return incomingSilence > 0 ? incomingSilence + 1 : 0
    }

    /// Moves the transition from `previous` `bars` later without moving either track in the set: the
    /// previous track plays that much longer and this one starts that much further into itself. Each
    /// keeps at least one bar of its own outside the transition and a bar of its audio in it. Moved
    /// earlier than this track's silence allows, the transition takes the track along: the previous
    /// track ends earlier and this one keeps its cue in.
    public func movingTransition(by bars: Int, after previous: PlacedEntry) -> (previousCueOut: Int, cueIn: Int) {
        let earliest = min(0, previous.earliestMixOutBar - mixInBar(after: previous))
        let latest = max(0, min(previous.barCount + silenceLimit - previous.cueOutBar, cueOutBar - 1 - overlapBars - cueInBar))
        let shift = bars.clamped(to: earliest...latest)
        return (previous.cueOutBar + shift, cueInBar + max(shift, min(0, -silenceLimit - cueInBar)))
    }
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

    /// Analyzed tracks that play at `bar`.
    public func heard(atBar bar: Double) -> [PlacedEntry] {
        entries.filter { $0.grid != nil && Double($0.startBar) <= bar && bar < Double($0.endBar) }
    }

    /// Bars that `bar` of `old` moves by in this layout when what plays there goes on unchanged:
    /// the same tracks, each at the same place in it, whatever the tempo of each layout. Nil when the
    /// edit changes what plays at `bar`.
    public func shift(from old: SetLayout, atBar bar: Double) -> Int? {
        let heard = old.heard(atBar: bar)
        let edited = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        var shift = 0
        for (index, entry) in heard.enumerated() {
            guard let now = edited[entry.id], now.file == entry.file, now.grid == entry.grid else { return nil }
            let moved = now.trackOrigin - entry.trackOrigin
            guard index == 0 || moved == shift else { return nil }
            shift = moved
        }
        return Set(self.heard(atBar: bar + Double(shift)).map(\.id)) == Set(heard.map(\.id)) ? shift : nil
    }

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
            let cueOut = max(cueIn + 1, entry.cueOutBar ?? TransitionPlanner.automaticCueOut(info.analysis, barCount: barCount, phraseBars: phraseBars))

            var overlap = 0
            var swap = 0
            var fadeIn = 0
            var fadeOut = 0
            var start = 0
            if let previous = placed.last {
                let previousInfo = tracks[previous.id]
                // Two parts of a split track follow each other with a cut: overlapping, the track would play over itself.
                let automatic = previous.file == entry.file ? 0 : TransitionPlanner.automaticOverlap(
                    outgoing: previousInfo?.analysis, outgoingCueOut: previous.cueOutBar,
                    incoming: info.analysis, incomingCueIn: cueIn, phraseBars: phraseBars
                )
                // The previous track keeps a bar of its own between its transitions: never three tracks at once.
                let longest = min(previous.lengthBars - previous.overlapBars, cueOut - cueIn) - 1
                overlap = max(0, min(entry.overlapBars ?? automatic, longest))
                swap = min(max(0, entry.bassSwapBar ?? overlap / 2), overlap)
                fadeIn = min(max(0, entry.fadeInBars ?? TransitionPlanner.automaticFadeBars(overlap: overlap)), overlap)
                fadeOut = min(max(0, entry.fadeOutBars ?? TransitionPlanner.automaticFadeBars(overlap: overlap)), overlap)
                start = previous.endBar - overlap
            }
            placed.append(PlacedEntry(
                id: entry.id, file: entry.file, startBar: start, cueInBar: cueIn, cueOutBar: cueOut,
                overlapBars: overlap, bassSwapBar: swap, fadeInBars: fadeIn, fadeOutBars: fadeOut, barCount: barCount, grid: info.analysis?.grid
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
    /// Part of an overlap each track takes to fade by default: both play at full volume in the middle.
    static let fadeFraction = 0.25

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

    /// A quarter of the overlap, in whole bars, and at least one bar when there is an overlap.
    static func automaticFadeBars(overlap: Int) -> Int {
        min(overlap, max(1, Int((Double(overlap) * fadeFraction).rounded())))
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

extension Comparable {
    public func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
