import Foundation

/// Deterministic test signals at the analysis sample rate.
enum Synth {
    static let sampleRate = 22_050.0

    enum Layer { case kick, swellingKick, bass, hats, pad, riser }

    /// A 4/4 track of `bars` bars where `layers(bar)` decides what plays in each bar.
    static func track(bpm: Double, bars: Int, leadIn: Double = 0, layers: (Int) -> Set<Layer>) -> [Float] {
        let beat = 60 / bpm
        let total = leadIn + Double(bars * 4) * beat + 1
        var x = [Float](repeating: 0, count: Int(total * sampleRate))
        var noise = SplitMix(seed: 7)
        for bar in 0..<bars {
            let active = layers(bar)
            let barStart = leadIn + Double(bar * 4) * beat
            if active.contains(.pad) {
                for f in [220.0, 261.63, 329.63] { addTone(&x, at: barStart, duration: 4 * beat, frequency: f, gain: 0.06) }
            }
            if active.contains(.riser) {
                let start = Int(barStart * sampleRate)
                let length = Int(4 * beat * sampleRate)
                let progress = Float(bar % 8) / 8
                for i in 0..<length where start + i < x.count {
                    let ramp = 0.02 + 0.3 * (progress + Float(i) / Float(length) / 8)
                    x[start + i] += ramp * noise.nextSigned()
                }
            }
            for b in 0..<4 {
                let t = barStart + Double(b) * beat
                if active.contains(.kick) { addKick(&x, at: t) }
                if active.contains(.swellingKick) { addSwellingKick(&x, at: t) }
                if active.contains(.bass) { addBass(&x, at: t + beat / 2) }
                if active.contains(.hats) { addNoiseBurst(&x, at: t + beat / 2, duration: 0.02, gain: 0.15, noise: &noise) }
            }
        }
        return x
    }

    static func addKick(_ x: inout [Float], at t: Double) {
        let start = Int(t * sampleRate)
        var phase = 0.0
        for i in 0..<Int(0.3 * sampleRate) where start + i < x.count {
            let time = Double(i) / sampleRate
            let frequency = 45 + 105 * exp(-time / 0.03)
            phase += 2 * Double.pi * frequency / sampleRate
            x[start + i] += Float(0.9 * sin(phase) * exp(-time / 0.08))
        }
    }

    /// A kick whose sub then swells in two steps over 70 ms: its sub-band rise peaks several
    /// times, the last one long after the attack.
    static func addSwellingKick(_ x: inout [Float], at t: Double) {
        addKick(&x, at: t)
        let start = Int(t * sampleRate)
        for i in 0..<Int(0.35 * sampleRate) where start + i < x.count {
            let time = Double(i) / sampleRate
            let steps = zip([0.03, 0.07], [0.75, 0.25]).map { onset, size in size * min(1, max(0, (time - onset) / 0.005)) }
            let swell = 0.9 * steps.reduce(0, +) * (time > 0.2 ? exp(-(time - 0.2) / 0.1) : 1)
            x[start + i] += Float(swell * sin(2 * Double.pi * 48 * time))
        }
    }

    static func addBass(_ x: inout [Float], at t: Double) {
        let start = Int(t * sampleRate)
        for i in 0..<Int(0.2 * sampleRate) where start + i < x.count {
            let time = Double(i) / sampleRate
            x[start + i] += Float(0.5 * sin(2 * Double.pi * 55 * time) * min(1, time / 0.005) * exp(-time / 0.12))
        }
    }

    static func addTone(_ x: inout [Float], at t: Double, duration: Double, frequency: Double, gain: Float, harmonics: Int = 1) {
        let start = Int(t * sampleRate)
        for i in 0..<Int(duration * sampleRate) where start + i < x.count {
            let time = Double(i) / sampleRate
            for h in 1...harmonics {
                x[start + i] += gain / Float(h) * Float(sin(2 * Double.pi * frequency * Double(h) * time))
            }
        }
    }

    static func addNoiseBurst(_ x: inout [Float], at t: Double, duration: Double, gain: Float, noise: inout SplitMix) {
        let start = Int(t * sampleRate)
        for i in 0..<Int(duration * sampleRate) where start + i < x.count {
            x[start + i] += gain * noise.nextSigned()
        }
    }
}

struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func nextSigned() -> Float {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Float(z >> 40) / Float(1 << 23) - 1
    }
}
