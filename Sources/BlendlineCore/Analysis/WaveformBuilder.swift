import Accelerate
import Foundation

enum WaveformBuilder {
    /// Percentile of each band's peaks mapped to full scale, so brief spikes don't flatten the drawing.
    private static let fullScalePercentile = 0.995

    static func build(_ bands: BandSignals, pointsPerSecond: Double) -> Waveform {
        let count = Int(bands.duration * pointsPerSecond)
        func envelope(_ x: [Float]) -> Data {
            var peaks = [Float](repeating: 0, count: count)
            x.withUnsafeBufferPointer { buffer in
                for i in 0..<count {
                    let a = Int(Double(i) / pointsPerSecond * bands.sampleRate)
                    let b = min(x.count, Int(Double(i + 1) / pointsPerSecond * bands.sampleRate))
                    guard b > a else { continue }
                    vDSP_maxmgv(buffer.baseAddress! + a, 1, &peaks[i], vDSP_Length(b - a))
                }
            }
            let scale = DSP.percentile(peaks, fullScalePercentile)
            guard scale > 0 else { return Data(count: count) }
            return Data(peaks.map { UInt8(min(255, ($0 / scale * 255).rounded())) })
        }
        return Waveform(pointsPerSecond: pointsPerSecond, low: envelope(bands.low), mid: envelope(bands.mid), high: envelope(bands.high))
    }
}
