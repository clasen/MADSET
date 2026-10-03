import AVFoundation
import Foundation
import Testing
@testable import MADSETCore

@Suite struct PipelineTests {
    private let config = AppConfig.current.analysis

    /// 44.1 kHz stereo file of a synthetic 128 BPM loop, so decoding has to resample and downmix.
    private func writeTestFile(seconds: Double) throws -> URL {
        let loop = Synth.track(bpm: 128, bars: Int(seconds / (4 * 60 / 128))) { _ in [.kick, .bass, .hats] }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let frames = AVAudioFrameCount(loop.count * 2)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            let sample = loop[i / 2] * 0.5
            buffer.floatChannelData![0][i] = sample
            buffer.floatChannelData![1][i] = sample
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "madset-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    @Test func decodesToMonoAtTheAnalysisRate() throws {
        let url = try writeTestFile(seconds: 20)
        let samples = try AudioDecoder.decodeMono(url: url, sampleRate: config.sampleRate)
        let duration = try AudioDecoder.duration(url: url)
        #expect(abs(Double(samples.count) / config.sampleRate - duration) < 0.05)
    }

    @Test func analyzesOnceThenServesFromCache() async throws {
        let url = try writeTestFile(seconds: 30)
        let directory = FileManager.default.temporaryDirectory.appending(path: "madset-cache-\(UUID().uuidString)")
        let pipeline = AnalysisPipeline(config: config, cache: AnalysisCache(directory: directory, analysis: config))

        let first = try await pipeline.analyze(url: url, needsKey: true)
        let second = try await pipeline.analyze(url: url, needsKey: true)

        #expect(!first.fromCache)
        #expect(second.fromCache)
        #expect(first.analysis == second.analysis)
        #expect(abs(first.analysis.grid.bpm - 128) < 0.01)
    }

    @Test func modifiedFilesAreAnalyzedAgain() throws {
        let url = try writeTestFile(seconds: 10)
        let cache = AnalysisCache(directory: FileManager.default.temporaryDirectory, analysis: config)
        let before = try cache.entryURL(for: url, needsKey: false)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: url.path)
        #expect(try cache.entryURL(for: url.standardizedFileURL, needsKey: false) != before)
    }

    @Test func limitsConcurrency() async {
        let counter = Counter()
        await forEachConcurrently(Array(0..<40), limit: 3, operation: { _ in
            await counter.enter()
            try? await Task.sleep(for: .milliseconds(5))
            await counter.leave()
        }, onResult: { _, _ in })
        #expect(await counter.peak == 3)
    }

    @Test func scannerExpandsFoldersInPathOrder() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "madset-scan-\(UUID().uuidString)")
        let nested = root.appending(path: "b")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for path in ["a 10.mp3", "a 2.MP3", "notes.txt", "b/c.flac", ".hidden.mp3"] {
            try Data().write(to: root.appending(path: path))
        }
        let prefix = root.resolvingSymlinksInPath().path + "/"
        let names = AudioFileScanner.audioFiles(in: [root]).map { $0.resolvingSymlinksInPath().path.replacingOccurrences(of: prefix, with: "") }
        #expect(names == ["a 2.MP3", "a 10.mp3", "b/c.flac"])
    }
}

private actor Counter {
    private var current = 0
    private(set) var peak = 0
    func enter() { current += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
}
