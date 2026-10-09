import Foundation

/// The decoded track split into the bands every analysis step reads.
struct BandSignals {
    let full: [Float]
    let low: [Float]
    /// Below 90 Hz: kick body and sub bass.
    let sub: [Float]
    let mid: [Float]
    let high: [Float]
    let sampleRate: Double

    var duration: Double { Double(full.count) / sampleRate }

    static let lowCutoff = 150.0
    static let subCutoff = 90.0
    static let highCutoff = 2_500.0

    init(_ x: [Float], sampleRate: Double) {
        full = x
        low = DSP.filter(x, kind: .lowPass, cutoff: Self.lowCutoff, sampleRate: sampleRate, sections: 2)
        sub = DSP.filter(low, kind: .lowPass, cutoff: Self.subCutoff, sampleRate: sampleRate, sections: 2)
        let aboveLow = DSP.filter(x, kind: .highPass, cutoff: Self.lowCutoff, sampleRate: sampleRate, sections: 2)
        mid = DSP.filter(aboveLow, kind: .lowPass, cutoff: Self.highCutoff, sampleRate: sampleRate, sections: 2)
        high = DSP.filter(x, kind: .highPass, cutoff: Self.highCutoff, sampleRate: sampleRate, sections: 2)
        self.sampleRate = sampleRate
    }
}

/// Finds downbeats and phrase alignment, then labels each phrase with a DJ phase.
enum StructureAnalyzer {
    struct Result {
        let grid: BeatGrid
        let sections: [Section]
        let kickPresence: [Float]
    }

    /// Per-beat measurements, in dB except `kick` (0 or 1).
    private struct BeatFeatures {
        var loud: Float
        var bass: Float
        var mid: Float
        var high: Float
        var kick: Float

        var vector: [Float] { [loud, bass, mid, high, kick * 12] }
    }

    /// Kick detection compares each beat's sub-band envelope with the track's average beat shape
    /// (the kick "template"). A beat has a kick when its shape correlates with the template and its
    /// pulse is at least this fraction as deep. Self-calibrating: kick length and mix level don't matter.
    private static let kickCorrelation: Float = 0.55
    private static let kickRelativeDepth: Float = 0.5
    /// Beats whose sub level is below this fraction of the track's loud beats have no kick
    /// (their normalized shape would be noise).
    private static let kickMinimumLevel: Float = 0.1
    /// Below this template depth the track has no beat-locked low end at all (ambient, beatless).
    private static let minimumTemplateDepth: Float = 0.3
    private static let profileBins = 16

    /// Phrases count as "full" (main part of the track) within these margins of the loudest kick phrases.
    private static let fullLoudnessMargin: Float = 3
    private static let fullBassMargin: Float = 4
    /// Rise across a phrase, in dB, that marks a buildup.
    private static let buildupRise: Float = 2

    static func analyze(_ bands: BandSignals, sub: OnsetEnvelope, tempo: TempoEstimate, phraseBars: Int) -> Result {
        let period = 60 / tempo.bpm
        let beatTimes = Array(stride(from: tempo.firstBeat, to: bands.duration - period, by: period))
        let beats = measureBeats(bands, sub: sub, beatTimes: beatTimes, period: period)

        let downbeatOffset = bestOffset(beats.map(\.vector), groupSize: 4, window: 4)
        let firstDownbeat = tempo.firstBeat + Double(downbeatOffset) * period
        let bars = groupIntoBars(beats, from: downbeatOffset)
        let phraseOffset = bars.count >= phraseBars * 2
            ? bestOffset(bars.map(\.vector), groupSize: phraseBars, window: 4)
            : 0

        let grid = BeatGrid(bpm: tempo.bpm, firstDownbeat: firstDownbeat, phraseOffsetBars: phraseOffset, confidence: tempo.confidence)
        let sections = labelPhrases(bars: bars, phraseBars: phraseBars, phraseOffset: phraseOffset)
        return Result(grid: grid, sections: sections, kickPresence: bars.map(\.kick))
    }

    private static func measureBeats(_ bands: BandSignals, sub: OnsetEnvelope, beatTimes: [Double], period: Double) -> [BeatFeatures] {
        let sr = bands.sampleRate
        let kicks = detectKicks(sub, beatTimes: beatTimes, period: period)
        let measured = zip(beatTimes, kicks).map { t, kick in
            BeatFeatures(
                loud: DSP.decibels(DSP.meanSquare(bands.full, from: t, to: t + period, sampleRate: sr)),
                bass: DSP.decibels(DSP.meanSquare(bands.low, from: t + period / 2, to: t + period, sampleRate: sr)),
                mid: DSP.decibels(DSP.meanSquare(bands.mid, from: t, to: t + period, sampleRate: sr)),
                high: DSP.decibels(DSP.meanSquare(bands.high, from: t, to: t + period, sampleRate: sr)),
                kick: kick ? 1 : 0
            )
        }
        return clampedToDynamicRange(measured)
    }

    /// Levels further than this below a feature's loud beats are noise floor; their differences are meaningless.
    private static let dynamicRange: Float = 30

    private static func clampedToDynamicRange(_ beats: [BeatFeatures]) -> [BeatFeatures] {
        func floor(_ value: (BeatFeatures) -> Float) -> Float { DSP.percentile(beats.map(value), 0.95) - dynamicRange }
        let loud = floor(\.loud), bass = floor(\.bass), mid = floor(\.mid), high = floor(\.high)
        return beats.map {
            BeatFeatures(loud: max($0.loud, loud), bass: max($0.bass, bass), mid: max($0.mid, mid), high: max($0.high, high), kick: $0.kick)
        }
    }

    private static func detectKicks(_ sub: OnsetEnvelope, beatTimes: [Double], period: Double) -> [Bool] {
        let envelope = sub.level
        let frameRate = sub.frameRate

        let raw = beatTimes.map { t -> [Float] in
            var sums = [Float](repeating: 0, count: profileBins)
            var counts = [Float](repeating: 0, count: profileBins)
            let a = Int(t * frameRate)
            let b = min(envelope.count, Int((t + period) * frameRate))
            guard b > a else { return sums }
            for i in a..<b {
                let bin = min(profileBins - 1, (i - a) * profileBins / (b - a))
                sums[bin] += envelope[i]
                counts[bin] += 1
            }
            return zip(sums, counts).map { $1 > 0 ? $0 / $1 : 0 }
        }
        let levels = raw.map { $0.reduce(0, +) / Float(profileBins) }
        let audible = DSP.percentile(levels, 0.9) * kickMinimumLevel
        let profiles = zip(raw, levels).map { profile, level -> [Float]? in
            level > audible && level > 0 ? profile.map { $0 / level } : nil
        }
        let measured = profiles.compactMap { $0 }
        guard !measured.isEmpty else { return profiles.map { _ in false } }
        var template = [Float](repeating: 0, count: profileBins)
        for profile in measured {
            for k in 0..<profileBins { template[k] += profile[k] / Float(measured.count) }
        }
        let templateDepth = depth(template)
        guard templateDepth >= minimumTemplateDepth else { return profiles.map { _ in false } }
        return profiles.map { profile in
            guard let profile else { return false }
            return correlation(profile, template) >= kickCorrelation && depth(profile) >= templateDepth * kickRelativeDepth
        }
    }

    /// Peak-to-trough range of a mean-normalized profile.
    private static func depth(_ profile: [Float]) -> Float {
        (profile.max() ?? 0) - (profile.min() ?? 0)
    }

    private static func correlation(_ a: [Float], _ b: [Float]) -> Float {
        let ma = a.reduce(0, +) / Float(a.count)
        let mb = b.reduce(0, +) / Float(b.count)
        var numerator: Float = 0, va: Float = 0, vb: Float = 0
        for i in a.indices {
            numerator += (a[i] - ma) * (b[i] - mb)
            va += (a[i] - ma) * (a[i] - ma)
            vb += (b[i] - mb) * (b[i] - mb)
        }
        return va > 0 && vb > 0 ? numerator / (va * vb).squareRoot() : 0
    }

    /// Offset (0..<groupSize) where the strongest changes land: each position's novelty is the
    /// distance between the `window` units before and after it, and only local maxima vote, so a
    /// boundary counts once instead of smearing over its neighbors.
    private static func bestOffset(_ vectors: [[Float]], groupSize: Int, window: Int) -> Int {
        guard vectors.count > window * 2 else { return 0 }
        func mean(_ range: Range<Int>) -> [Float] {
            var sum = [Float](repeating: 0, count: vectors[0].count)
            for i in range { for d in sum.indices { sum[d] += vectors[i][d] } }
            return sum.map { $0 / Float(range.count) }
        }
        var novelty = [Float](repeating: 0, count: vectors.count)
        for i in window...(vectors.count - window) {
            novelty[i] = zip(mean((i - window)..<i), mean(i..<(i + window))).map { abs($0 - $1) }.reduce(0, +)
        }
        var scores = [Float](repeating: 0, count: groupSize)
        for i in novelty.indices where novelty[i] > 0 {
            let neighborhood = max(0, i - 2)...min(novelty.count - 1, i + 2)
            if neighborhood.allSatisfy({ $0 == i || novelty[$0] < novelty[i] }) {
                scores[i % groupSize] += novelty[i]
            }
        }
        return scores.indices.max(by: { scores[$0] < scores[$1] }) ?? 0
    }

    private static func groupIntoBars(_ beats: [BeatFeatures], from offset: Int) -> [BeatFeatures] {
        stride(from: offset, to: beats.count - 3, by: 4).map { start in
            let bar = beats[start..<(start + 4)]
            let n = Float(bar.count)
            return BeatFeatures(
                loud: bar.map(\.loud).reduce(0, +) / n,
                bass: bar.map(\.bass).reduce(0, +) / n,
                mid: bar.map(\.mid).reduce(0, +) / n,
                high: bar.map(\.high).reduce(0, +) / n,
                kick: bar.map(\.kick).reduce(0, +) / n
            )
        }
    }

    private struct Phrase {
        let bars: Range<Int>
        let kick: Float
        let loud: Float
        let bass: Float
        let rise: Float
    }

    private static func labelPhrases(bars: [BeatFeatures], phraseBars: Int, phraseOffset: Int) -> [Section] {
        guard !bars.isEmpty else { return [] }
        var boundaries = [0]
        var next = phraseOffset == 0 ? phraseBars : phraseOffset
        while next < bars.count {
            boundaries.append(next)
            next += phraseBars
        }
        boundaries.append(bars.count)

        let phrases: [Phrase] = zip(boundaries, boundaries.dropFirst()).map { start, end in
            let slice = bars[start..<end]
            let n = Float(slice.count)
            let half = max(1, slice.count / 2)
            let firstHalf = slice.prefix(half)
            let lastHalf = slice.suffix(half)
            func avg(_ s: ArraySlice<BeatFeatures>, _ f: (BeatFeatures) -> Float) -> Float {
                s.map(f).reduce(0, +) / Float(s.count)
            }
            let rise = max(avg(lastHalf, \.loud) - avg(firstHalf, \.loud), avg(lastHalf, \.high) - avg(firstHalf, \.high))
            return Phrase(
                bars: start..<end,
                kick: slice.map(\.kick).reduce(0, +) / n,
                loud: avg(slice, \.loud),
                bass: avg(slice, \.bass),
                rise: rise
            )
        }

        let kickBars = bars.filter { $0.kick >= 0.5 }
        let loudReference = DSP.percentile(kickBars.map(\.loud), 0.9)
        let bassReference = DSP.percentile(kickBars.map(\.bass), 0.9)
        let full = phrases.map {
            $0.kick >= 0.5 && $0.loud >= loudReference - fullLoudnessMargin && $0.bass >= bassReference - fullBassMargin
        }

        var phases = phrases.map { $0.kick >= 0.5 ? Phase.groove : Phase.breakdown }
        if let first = full.firstIndex(of: true), let last = full.lastIndex(of: true) {
            for i in 0..<first { phases[i] = .intro }
            for i in (last + 1)..<phrases.count { phases[i] = .outro }
            for i in 0..<last where !full[i] && full[i + 1] && phrases[i].rise >= buildupRise {
                phases[i] = .buildup
            }
            for i in first...last where full[i] {
                let previous = i > 0 ? phases[i - 1] : .intro
                phases[i] = [.breakdown, .buildup, .drop].contains(previous) ? .drop : .groove
            }
        }

        var sections: [Section] = []
        for (phrase, phase) in zip(phrases, phases) {
            if let last = sections.last, last.phase == phase {
                sections[sections.count - 1].endBar = phrase.bars.upperBound
            } else {
                sections.append(Section(phase: phase, startBar: phrase.bars.lowerBound, endBar: phrase.bars.upperBound))
            }
        }
        return sections
    }
}
