import Accelerate
import Foundation

/// Power-of-two real FFT helpers built on vDSP's packed real format.
struct RealFFT {
    let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup

    init(size: Int) {
        precondition(size >= 2 && size & (size - 1) == 0, "FFT size must be a power of two: \(size)")
        self.size = size
        log2n = vDSP_Length(size.trailingZeroBitCount)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            preconditionFailure("vDSP_create_fftsetup failed for size \(size)")
        }
        self.setup = setup
    }

    func destroy() { vDSP_destroy_fftsetup(setup) }

    static func size(atLeast n: Int) -> Int {
        var size = 2
        while size < n { size <<= 1 }
        return size
    }

    /// |X[k]|^2 for k in 0..<size/2 of `x` zero-padded (or truncated) to `size`. Unnormalized.
    func powerSpectrum(_ x: UnsafeBufferPointer<Float>) -> [Float] {
        let half = size / 2
        var input = [Float](repeating: 0, count: size)
        let copied = min(x.count, size)
        input.withUnsafeMutableBufferPointer { dst in
            _ = memcpy(dst.baseAddress!, x.baseAddress!, copied * MemoryLayout<Float>.stride)
        }
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                input.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
                power[0] = rp[0] * rp[0]
            }
        }
        return power
    }

    /// Inverse transform of a real, even spectrum (e.g. a power spectrum) → circular autocorrelation, unnormalized.
    func inverseOfRealSpectrum(_ spectrum: [Float]) -> [Float] {
        let half = size / 2
        precondition(spectrum.count == half, "Spectrum must have size/2 bins")
        var real = spectrum
        var imag = [Float](repeating: 0, count: half)
        var output = [Float](repeating: 0, count: size)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                output.withUnsafeMutableBytes { raw in
                    vDSP_ztoc(&split, 1, raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(half))
                }
            }
        }
        return output
    }
}
