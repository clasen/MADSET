import Accelerate
import Foundation

/// Onset envelope of one band, sampled at `frameRate`.
struct OnsetEnvelope {
    let values: [Float]
    /// Smoothed amplitude the onsets were derived from.
    let level: [Float]
    let frameRate: Double

    /// Time at the center of frame `i`.
    func time(ofFrame i: Int) -> Double { (Double(i) + 0.5) / frameRate }

    /// Positive slope of the smoothed amplitude: peaks at every attack in the band.
    /// Amplitude (not log) keeps faint attacks rising out of silence from outweighing the kick.
    static func amplitudeRise(of band: [Float], sampleRate: Double, hop: Int) -> OnsetEnvelope {
        let energy = DSP.frameEnergy(band, hop: hop)
        let smoothing = 8
        var smoothed = [Float](repeating: 0, count: energy.count)
        var running: Float = 0
        for i in 0..<(energy.count + smoothing / 2) {
            if i < energy.count { running += energy[i] }
            if i >= smoothing { running -= energy[i - smoothing] }
            let center = i - smoothing / 2
            if center >= 0, center < energy.count {
                smoothed[center] = (max(running, 0) / Float(smoothing)).squareRoot()
            }
        }
        var onset = [Float](repeating: 0, count: energy.count)
        if energy.count > 2 {
            for i in 1..<(energy.count - 1) {
                onset[i] = max(0, smoothed[i + 1] - smoothed[i - 1])
            }
        }
        return OnsetEnvelope(values: onset, level: smoothed, frameRate: sampleRate / Double(hop))
    }
}

struct TempoEstimate {
    let bpm: Double
    /// Time of the first beat at or after zero.
    let firstBeat: Double
    let confidence: Double
}

public enum BeatTracker {
    public enum Failure: Error { case noRhythmicContent }

    /// `sub` locates kicks (their body is the strongest sub-band event); `attack`, from a wider low
    /// band, times them, since the kick's pitch sweep reaches the sub band some milliseconds late.
    static func estimate(sub: OnsetEnvelope, attack: OnsetEnvelope, minBPM: Double, maxBPM: Double) throws -> TempoEstimate {
        precondition(sub.values.count == attack.values.count && sub.frameRate == attack.frameRate, "Onset envelopes must share frames")
        let coarse = try coarseTempo(sub, minBPM: minBPM, maxBPM: maxBPM)
        return refine(sub, attack: attack, around: coarse, span: 0.15, step: 0.001)
    }

    /// Tempo whose period is both strongly periodic (spectrum peaks at the tempo and its harmonics,
    /// rejects half and three-quarter tempo) and self-similar (autocorrelation peak, rejects double tempo).
    private static func coarseTempo(_ onset: OnsetEnvelope, minBPM: Double, maxBPM: Double) throws -> Double {
        var centered = onset.values
        let mean = vDSP.mean(centered)
        guard mean > 0 else { throw Failure.noRhythmicContent }
        vDSP.add(-mean, centered, result: &centered)

        let fft = RealFFT(size: RealFFT.size(atLeast: centered.count) * 2)
        defer { fft.destroy() }
        let power = centered.withUnsafeBufferPointer { fft.powerSpectrum($0) }
        let acf = fft.inverseOfRealSpectrum(power)
        guard acf[0] > 0 else { throw Failure.noRhythmicContent }

        func interpolated(_ a: [Float], _ x: Double) -> Double {
            let i = Int(x)
            guard i + 1 < a.count, i >= 0 else { return 0 }
            let f = Float(x - Double(i))
            return Double(a[i] * (1 - f) + a[i + 1] * f)
        }
        let binsPerHz = Double(fft.size) / onset.frameRate
        let candidates = stride(from: minBPM, through: maxBPM, by: 0.05).map { bpm -> (bpm: Double, dft: Double, acf: Double) in
            let periodicity = [1.0, 2.0, 3.0, 4.0].map { harmonic -> Double in
                let bin = harmonic * bpm / 60 * binsPerHz
                return max(interpolated(power, bin - 1), interpolated(power, bin), interpolated(power, bin + 1)).squareRoot()
            }.reduce(0, +)
            let lag = 60 / bpm * onset.frameRate
            let selfSimilarity = [1.0, 2.0, 4.0].map { interpolated(acf, lag * $0) }.reduce(0, +) / 3
            return (bpm, periodicity, max(0, selfSimilarity / Double(acf[0])))
        }
        let maxDFT = candidates.map(\.dft).max() ?? 0
        guard maxDFT > 0 else { throw Failure.noRhythmicContent }
        guard let best = candidates.max(by: { $0.dft / maxDFT * $0.acf < $1.dft / maxDFT * $1.acf }) else {
            throw Failure.noRhythmicContent
        }
        return best.bpm
    }

    /// Circular fit of onset times to a beat period. The tempo maximizes phase locking at the beat
    /// frequency and its 2nd and 4th harmonics, where kick and offbeat bass reinforce instead of
    /// cancelling. The beat phase is then the onset cluster that carries the most sub-band body.
    private static func refine(_ onset: OnsetEnvelope, attack: OnsetEnvelope, around bpm: Double, span: Double, step: Double) -> TempoEstimate {
        let threshold = DSP.percentile(onset.values, 0.995) * 0.1
        var times: [Float] = []
        var weights: [Float] = []
        for (i, v) in onset.values.enumerated() where v > threshold {
            times.append(Float(onset.time(ofFrame: i)))
            weights.append(v)
        }
        let totalWeight = Double(vDSP.sum(weights))
        let harmonics: [Float] = [1, 2, 4]
        var theta = [Float](repeating: 0, count: times.count)
        var sines = theta
        var cosines = theta

        var best = (bpm: bpm, score: -1.0)
        for candidate in stride(from: bpm - span, through: bpm + span, by: step) {
            var score = 0.0
            for harmonic in harmonics {
                vDSP.multiply(harmonic * Float(2 * Double.pi * candidate / 60), times, result: &theta)
                var count = Int32(times.count)
                vvsincosf(&sines, &cosines, theta, &count)
                let s = Double(vDSP.dot(weights, sines))
                let c = Double(vDSP.dot(weights, cosines))
                score += (s * s + c * c).squareRoot()
            }
            if score > best.score { best = (candidate, score) }
        }
        let period = 60 / best.bpm
        let confidence = totalWeight > 0 ? best.score / (Double(harmonics.count) * totalWeight) : 0
        return TempoEstimate(bpm: best.bpm, firstBeat: kickPhase(onset, attack: attack, period: period), confidence: confidence)
    }

    private static let phaseBins = 48

    /// Time in 0..<period of the kick attack: among the strong onset clusters of the folded beat,
    /// the one followed by the most sub-band energy, refined to the circular mean of the attack
    /// onsets around it. A cluster is the highest onset within `window`: a kick whose sub swells
    /// slowly rises in ripples, and counting each ripple would favor the last, which is followed by
    /// the most body but lies past the attack.
    private static func kickPhase(_ onset: OnsetEnvelope, attack: OnsetEnvelope, period: Double) -> Double {
        func bin(ofFrame i: Int) -> Int {
            let phase = onset.time(ofFrame: i) / period
            return min(phaseBins - 1, Int((phase - phase.rounded(.down)) * Double(phaseBins)))
        }
        var onsetFold = [Float](repeating: 0, count: phaseBins)
        var levelFold = [Float](repeating: 0, count: phaseBins)
        for i in onset.values.indices {
            let b = bin(ofFrame: i)
            onsetFold[b] += onset.values[i]
            levelFold[b] += onset.level[i] * onset.level[i]
        }
        let window = phaseBins / 8
        let body = phaseBins / 4
        let strongest = onsetFold.max() ?? 0
        var kickBin = 0
        var bestBody: Float = -1
        for b in 0..<phaseBins {
            let neighborhood = (-window...window).map { onsetFold[(b + $0 + phaseBins) % phaseBins] }
            guard onsetFold[b] >= strongest * 0.3, onsetFold[b] >= neighborhood.max() ?? 0 else { continue }
            let energy = (0..<body).map { levelFold[(b + $0) % phaseBins] }.reduce(0, +)
            if energy > bestBody { bestBody = energy; kickBin = b }
        }

        var s = 0.0, c = 0.0
        for i in attack.values.indices {
            var distance = abs(bin(ofFrame: i) - kickBin)
            distance = min(distance, phaseBins - distance)
            guard distance <= window else { continue }
            let angle = 2 * Double.pi * attack.time(ofFrame: i) / period
            s += Double(attack.values[i]) * sin(angle)
            c += Double(attack.values[i]) * cos(angle)
        }
        var phase = atan2(s, c) / (2 * Double.pi) * period
        phase = phase.truncatingRemainder(dividingBy: period)
        return phase < 0 ? phase + period : phase
    }
}
