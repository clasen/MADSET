import Accelerate
import Foundation

enum DSP {
    enum FilterKind { case lowPass, highPass }

    /// Butterworth-style cascade of `sections` identical RBJ biquads (Q = 1/sqrt 2).
    static func filter(_ x: [Float], kind: FilterKind, cutoff: Double, sampleRate: Double, sections: Int) -> [Float] {
        var biquad = cascade(kind, cutoff: cutoff, sampleRate: sampleRate, sections: sections)
        return biquad.apply(input: x)
    }

    /// Stateful filter of `sections` identical RBJ biquads (Q = 1/sqrt 2); two sections make a Linkwitz–Riley crossover.
    static func cascade(_ kind: FilterKind, cutoff: Double, sampleRate: Double, sections: Int) -> vDSP.Biquad<Float> {
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let q = 0.5.squareRoot()
        let alpha = sin(w0) / (2 * q)
        let cosW = cos(w0)
        let a0 = 1 + alpha
        let b: (Double, Double, Double)
        switch kind {
        case .lowPass: b = ((1 - cosW) / 2, 1 - cosW, (1 - cosW) / 2)
        case .highPass: b = ((1 + cosW) / 2, -(1 + cosW), (1 + cosW) / 2)
        }
        let section = [b.0 / a0, b.1 / a0, b.2 / a0, -2 * cosW / a0, (1 - alpha) / a0]
        let coefficients = Array([[Double]](repeating: section, count: sections).joined())
        guard let biquad = vDSP.Biquad(coefficients: coefficients, channelCount: 1, sectionCount: vDSP_Length(sections), ofType: Float.self) else {
            preconditionFailure("Invalid biquad coefficients for cutoff \(cutoff)")
        }
        return biquad
    }

    /// Mean square of consecutive, non-overlapping frames of `hop` samples.
    static func frameEnergy(_ x: [Float], hop: Int) -> [Float] {
        let frames = x.count / hop
        var out = [Float](repeating: 0, count: frames)
        x.withUnsafeBufferPointer { buffer in
            for i in 0..<frames {
                vDSP_measqv(buffer.baseAddress! + i * hop, 1, &out[i], vDSP_Length(hop))
            }
        }
        return out
    }

    /// Mean square of `x` between two times, clamped to the signal.
    static func meanSquare(_ x: [Float], from start: Double, to end: Double, sampleRate: Double) -> Float {
        let a = max(0, Int(start * sampleRate))
        let b = min(x.count, Int(end * sampleRate))
        guard b > a else { return 0 }
        var result: Float = 0
        x.withUnsafeBufferPointer { vDSP_measqv($0.baseAddress! + a, 1, &result, vDSP_Length(b - a)) }
        return result
    }

    static func decibels(_ power: Float) -> Float {
        10 * log10(max(power, 1e-12))
    }

    static func percentile(_ values: [Float], _ p: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[index]
    }
}
