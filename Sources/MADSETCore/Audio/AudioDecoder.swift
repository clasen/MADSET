@preconcurrency import AVFoundation

public enum AudioDecoderError: Error {
    case unsupportedFormat(URL)
    case conversionFailed(URL, String)
}

public enum AudioDecoder {
    /// Seconds before the header-reported end where a read failure is treated as end of stream.
    static let truncatedTailTolerance = 5.0

    /// Duration from the file header, without decoding.
    public static func duration(url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// Decodes the whole file to mono Float32 at `sampleRate`, for analysis.
    public static func decodeMono(url: URL, sampleRate: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        return try decode(file, url: url, sampleRate: sampleRate, channels: 1, quality: .medium)[0]
    }

    /// Decodes the whole file to stereo at `sampleRate`, for playback. Mono files play on both sides.
    public static func decodeStereo(url: URL, sampleRate: Double) throws -> PCMBuffer {
        let file = try AVAudioFile(forReading: url)
        if file.processingFormat.channelCount == 1 {
            let mono = try decode(file, url: url, sampleRate: sampleRate, channels: 1, quality: .high)[0]
            return PCMBuffer(channels: [mono, mono], sampleRate: sampleRate)
        }
        return PCMBuffer(channels: try decode(file, url: url, sampleRate: sampleRate, channels: 2, quality: .high), sampleRate: sampleRate)
    }

    private static func decode(_ file: AVAudioFile, url: URL, sampleRate: Double, channels: AVAudioChannelCount, quality: AVAudioQuality) throws -> [[Float]] {
        let inFormat = file.processingFormat
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw AudioDecoderError.unsupportedFormat(url)
        }
        converter.downmix = channels < inFormat.channelCount
        converter.sampleRateConverterQuality = quality.rawValue

        let chunk: AVAudioFrameCount = 65_536
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: chunk) else {
            throw AudioDecoderError.unsupportedFormat(url)
        }

        let expected = Int(Double(file.length) * sampleRate / inFormat.sampleRate) + Int(chunk)
        var samples = [[Float]](repeating: [], count: Int(channels))
        for c in samples.indices { samples[c].reserveCapacity(expected) }
        let input = InputState()

        while true {
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
                if input.finished || file.framePosition >= file.length {
                    input.finished = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: inBuffer, frameCount: chunk)
                } catch {
                    // MP3 lengths are estimated from the header and can overshoot the decodable
                    // frames; a failure inside that tail is the end of the stream, not an error.
                    let remaining = Double(file.length - file.framePosition) / inFormat.sampleRate
                    if remaining > truncatedTailTolerance { input.readError = error }
                    input.finished = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inBuffer
            }
            if let readError = input.readError { throw readError }
            if status == .error {
                throw AudioDecoderError.conversionFailed(url, conversionError?.localizedDescription ?? "unknown")
            }
            if let data = outBuffer.floatChannelData, outBuffer.frameLength > 0 {
                for c in samples.indices {
                    samples[c].append(contentsOf: UnsafeBufferPointer(start: data[c], count: Int(outBuffer.frameLength)))
                }
            }
            if status == .endOfStream || (status == .inputRanDry && input.finished) { break }
        }
        return samples
    }
}

/// Shared with the converter's input block, which AVAudioConverter calls synchronously on this thread.
private final class InputState: @unchecked Sendable {
    var finished = false
    var readError: Error?
}
