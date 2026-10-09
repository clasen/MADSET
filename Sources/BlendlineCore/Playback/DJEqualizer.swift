import Accelerate
import Foundation

/// Gains applied to a voice: overall level and the three EQ bands (1 = unity, 0 = kill).
struct MixGains: Equatable {
    var volume: Float = 1
    var low: Float = 1
    var mid: Float = 1
    var high: Float = 1
}

/// Three-band DJ isolator for one channel, built from Linkwitz–Riley (LR4) crossovers: the input
/// splits into low and rest, and the rest into mid and high. The bands sum to an all-pass, so at
/// unity gains the magnitude response is flat, and killing a band removes it properly.
struct DJEqualizer {
    static let lowCrossover = 250.0
    static let highCrossover = 2_500.0

    private var lowPass: vDSP.Biquad<Float>
    private var restPass: vDSP.Biquad<Float>
    private var midPass: vDSP.Biquad<Float>
    private var highPass: vDSP.Biquad<Float>
    private var low: [Float]
    private var rest: [Float]
    private var mid: [Float]
    private var high: [Float]

    init(sampleRate: Double, maxFrames: Int) {
        lowPass = DSP.cascade(.lowPass, cutoff: Self.lowCrossover, sampleRate: sampleRate, sections: 2)
        restPass = DSP.cascade(.highPass, cutoff: Self.lowCrossover, sampleRate: sampleRate, sections: 2)
        midPass = DSP.cascade(.lowPass, cutoff: Self.highCrossover, sampleRate: sampleRate, sections: 2)
        highPass = DSP.cascade(.highPass, cutoff: Self.highCrossover, sampleRate: sampleRate, sections: 2)
        low = [Float](repeating: 0, count: maxFrames)
        rest = low
        mid = low
        high = low
    }

    /// Adds the equalized `input` to `output`, ramping linearly from `from` to `to` gains over the frames.
    mutating func process(_ input: UnsafePointer<Float>, frames: Int, from: MixGains, to: MixGains, addingInto output: UnsafeMutablePointer<Float>) {
        precondition(frames <= low.count, "Block larger than the equalizer was sized for")
        let samples = UnsafeBufferPointer(start: input, count: frames)
        Self.apply(&lowPass, samples, into: &low, frames: frames)
        Self.apply(&restPass, samples, into: &rest, frames: frames)
        rest.withUnsafeBufferPointer { r in
            let restSamples = UnsafeBufferPointer(rebasing: r[0..<frames])
            Self.apply(&midPass, restSamples, into: &mid, frames: frames)
            Self.apply(&highPass, restSamples, into: &high, frames: frames)
        }
        let step = frames > 1 ? 1 / Float(frames - 1) : 0
        for i in 0..<frames {
            let t = Float(i) * step
            let volume = from.volume + (to.volume - from.volume) * t
            let lowGain = from.low + (to.low - from.low) * t
            let midGain = from.mid + (to.mid - from.mid) * t
            let highGain = from.high + (to.high - from.high) * t
            output[i] += volume * (lowGain * low[i] + midGain * mid[i] + highGain * high[i])
        }
    }

    private static func apply(_ filter: inout vDSP.Biquad<Float>, _ input: UnsafeBufferPointer<Float>, into buffer: inout [Float], frames: Int) {
        buffer.withUnsafeMutableBufferPointer { b in
            var target = UnsafeMutableBufferPointer(rebasing: b[0..<frames])
            filter.apply(input: input, output: &target)
        }
    }
}
