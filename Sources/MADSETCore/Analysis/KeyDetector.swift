import Accelerate
import Foundation

/// Key estimation from a track-wide, power-weighted chromagram matched against Krumhansl–Kessler profiles.
/// Power (not magnitude) weighting lets sustained tonal peaks dominate noise and percussion.
enum KeyDetector {
    private static let frameSize = 8_192
    private static let lowestFrequency = 50.0
    private static let highestFrequency = 2_000.0

    private static let majorProfile: [Float] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    private static let minorProfile: [Float] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    static func detect(_ x: [Float], sampleRate: Double) -> CamelotKey? {
        let chroma = chromagram(x, sampleRate: sampleRate)
        guard chroma.contains(where: { $0 > 0 }) else { return nil }

        var best: (score: Float, key: CamelotKey)?
        for tonic in 0..<12 {
            for (mode, profile) in [(CamelotKey.Mode.major, majorProfile), (.minor, minorProfile)] {
                let rotated = (0..<12).map { profile[($0 - tonic + 12) % 12] }
                let score = correlation(chroma, rotated)
                if best == nil || score > best!.score {
                    best = (score, CamelotKey(pitchClass: tonic, mode: mode))
                }
            }
        }
        return best?.key
    }

    private static func chromagram(_ x: [Float], sampleRate: Double) -> [Float] {
        let fft = RealFFT(size: frameSize)
        defer { fft.destroy() }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: frameSize, isHalfWindow: false)
        let binHz = sampleRate / Double(frameSize)
        let bins = Int(lowestFrequency / binHz)...min(frameSize / 2 - 1, Int(highestFrequency / binHz))
        let pitchClassOfBin = bins.map { bin -> Int in
            let midi = 69 + 12 * log2(Double(bin) * binHz / 440)
            return (Int(midi.rounded()) % 12 + 12) % 12
        }

        var chroma = [Float](repeating: 0, count: 12)
        var frame = [Float](repeating: 0, count: frameSize)
        var start = 0
        while start + frameSize <= x.count {
            x.withUnsafeBufferPointer { vDSP.multiply(UnsafeBufferPointer(rebasing: $0[start..<(start + frameSize)]), window, result: &frame) }
            let power = frame.withUnsafeBufferPointer { fft.powerSpectrum($0) }
            var frameChroma = [Float](repeating: 0, count: 12)
            for (i, bin) in bins.enumerated() {
                frameChroma[pitchClassOfBin[i]] += power[bin]
            }
            let total = frameChroma.reduce(0, +)
            if total > 0 {
                for pc in 0..<12 { chroma[pc] += frameChroma[pc] / total }
            }
            start += frameSize / 2
        }
        return chroma
    }

    private static func correlation(_ a: [Float], _ b: [Float]) -> Float {
        let ma = vDSP.mean(a), mb = vDSP.mean(b)
        let da = vDSP.add(-ma, a), db = vDSP.add(-mb, b)
        let denominator = (vDSP.sumOfSquares(da) * vDSP.sumOfSquares(db)).squareRoot()
        return denominator > 0 ? vDSP.dot(da, db) / denominator : 0
    }
}
