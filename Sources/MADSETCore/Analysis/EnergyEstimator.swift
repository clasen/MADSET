import Foundation

/// Estimates energy on Mixed In Key's 1–10 scale from audio, for tracks whose tags carry none.
/// A linear model over the main bars of the track (those near its loudest): louder, brighter,
/// bass-heavier and more compressed mixes rate higher. Fitted by least squares against the MIK
/// energy of ~1000 tagged tracks (cross-validated correlation 0.56, 98% within one level).
enum EnergyEstimator {
    struct Features {
        /// Mean level, in dB.
        var loudness: Float
        /// Low and high band levels relative to the full level, in dB.
        var low: Float
        var high: Float
        /// Onset strength of the high band relative to its level: sparse, sharp hats score high.
        var highFlux: Float
        /// Peak-to-RMS ratio, in dB; low values mean a dense, compressed mix.
        var crest: Float
    }

    /// Bars within this many dB of the loudest bars are the main part of the track.
    private static let mainMargin: Float = 6
    private static let onsetHop = 64

    private static let intercept: Float = 10.2515
    private static let loudnessWeight: Float = 0.0968
    private static let lowWeight: Float = 0.0663
    private static let highWeight: Float = 0.0774
    private static let highFluxWeight: Float = -9.9858
    private static let crestWeight: Float = -0.0802

    static func estimate(_ bands: BandSignals, grid: BeatGrid, barCount: Int) -> Int? {
        features(bands, grid: grid, barCount: barCount).map(estimate)
    }

    static func estimate(_ f: Features) -> Int {
        let score = intercept + loudnessWeight * f.loudness + lowWeight * f.low + highWeight * f.high
            + highFluxWeight * f.highFlux + crestWeight * f.crest
        return Int(min(10, max(1, score.rounded())))
    }

    static func features(_ bands: BandSignals, grid: BeatGrid, barCount: Int) -> Features? {
        let sr = bands.sampleRate
        let bars = (0..<barCount).map { grid.barStart($0)..<grid.barStart($0 + 1) }
        func level(_ x: [Float], _ bar: Range<Double>) -> Float {
            DSP.decibels(DSP.meanSquare(x, from: bar.lowerBound, to: bar.upperBound, sampleRate: sr))
        }
        let loud = bars.map { level(bands.full, $0) }
        let reference = DSP.percentile(loud, 0.95)
        let main = bars.indices.filter { loud[$0] >= reference - mainMargin }
        guard !main.isEmpty else { return nil }
        func mainMean(_ value: (Int) -> Float) -> Float { main.map(value).reduce(0, +) / Float(main.count) }

        let highOnset = OnsetEnvelope.amplitudeRise(of: bands.high, sampleRate: sr, hop: onsetHop)
        func highFlux(_ bar: Range<Double>) -> Float {
            let a = max(0, Int(bar.lowerBound * highOnset.frameRate))
            let b = min(highOnset.values.count, Int(bar.upperBound * highOnset.frameRate))
            guard b > a else { return 0 }
            let level = highOnset.level[a..<b].reduce(0, +)
            return level > 0 ? highOnset.values[a..<b].reduce(0, +) / level : 0
        }
        func crest(_ bar: Range<Double>) -> Float {
            let a = max(0, Int(bar.lowerBound * sr))
            let b = min(bands.full.count, Int(bar.upperBound * sr))
            guard b > a else { return 0 }
            let peak = bands.full[a..<b].reduce(0) { max($0, abs($1)) }
            return DSP.decibels(peak * peak) - level(bands.full, bar)
        }

        return Features(
            loudness: mainMean { loud[$0] },
            low: mainMean { level(bands.low, bars[$0]) - loud[$0] },
            high: mainMean { level(bands.high, bars[$0]) - loud[$0] },
            highFlux: mainMean { highFlux(bars[$0]) },
            crest: mainMean { crest(bars[$0]) }
        )
    }
}
