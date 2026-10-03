@preconcurrency import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Renders a whole `SetLayout` offline into an audio file, with the same mix the player plays.
public enum SetExporter {
    public enum Format: Sendable, CaseIterable {
        /// Uncompressed PCM, for mastering or uploading.
        case wav
        /// AAC in an MPEG-4 container (.m4a), for listening.
        case aac

        public var contentType: UTType {
            switch self {
            case .wav: .wav
            // Not `.mpeg4Audio`: its preferred extension is .mp4, which reads back as a movie.
            case .aac: UTType("com.apple.m4a-audio")!
            }
        }

        func settings(sampleRate: Double, config: AppConfig.Export) -> [String: Any] {
            switch self {
            case .wav:
                [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
                 AVLinearPCMBitDepthKey: config.wavBitDepth, AVLinearPCMIsFloatKey: false,
                 AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
            case .aac:
                [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
                 AVEncoderBitRateKey: config.aacBitRate]
            }
        }
    }

    /// Writes the set to `url`, whose extension must match `format`. `progress` gets the fraction
    /// done after every block; an error thrown from it cancels the export. A failed or cancelled
    /// export leaves no file behind.
    public static func export(
        _ layout: SetLayout, format: Format, to url: URL, sources: SourceCache,
        playback: AppConfig.Playback, config: AppConfig.Export, progress: (Double) throws -> Void
    ) throws {
        precondition(UTType(filenameExtension: url.pathExtension)?.conforms(to: format.contentType) == true,
                     "Export file extension does not match its format")
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings(sampleRate: playback.sampleRate, config: config),
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            defer { file.close() }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(playback.blockFrames)) else {
                preconditionFailure("Could not allocate the export buffer")
            }
            let renderer = SetRenderer(layout: layout, sources: sources, config: playback)
            let total = Int((layout.duration * playback.sampleRate).rounded())
            var done = 0
            while done < total {
                let frames = min(playback.blockFrames, total - done)
                renderer.render(frames: frames, left: buffer.floatChannelData![0], right: buffer.floatChannelData![1])
                buffer.frameLength = AVAudioFrameCount(frames)
                try file.write(from: buffer)
                done += frames
                try progress(Double(done) / Double(total))
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
