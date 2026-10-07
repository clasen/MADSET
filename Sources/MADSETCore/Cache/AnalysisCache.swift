import CryptoKit
import Foundation

/// On-disk store of analysis results, keyed by file path, size, modification date and analysis settings.
public struct AnalysisCache: Sendable {
    /// Bump when `TrackAnalysis` or the analysis algorithms change, so stale results are not reused.
    static let schemaVersion = 4

    public let directory: URL
    private let analysis: AppConfig.Analysis

    public init(directory: URL, analysis: AppConfig.Analysis) {
        self.directory = directory
        self.analysis = analysis
    }

    public static func userCaches(config: AppConfig) throws -> AnalysisCache {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return AnalysisCache(directory: caches.appending(path: config.cache.folderName, directoryHint: .isDirectory), analysis: config.analysis)
    }

    public func load(for url: URL, needsKey: Bool) throws -> TrackAnalysis? {
        let file = try entryURL(for: url, needsKey: needsKey)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try PropertyListDecoder().decode(TrackAnalysis.self, from: Data(contentsOf: file))
    }

    public func store(_ result: TrackAnalysis, for url: URL, needsKey: Bool) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(result).write(to: try entryURL(for: url, needsKey: needsKey), options: .atomic)
    }

    func entryURL(for url: URL, needsKey: Bool) throws -> URL {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let size = values.fileSize, let modified = values.contentModificationDate else {
            preconditionFailure("File system did not report size/date for \(url.path)")
        }
        let identity = [
            url.standardizedFileURL.path,
            String(size),
            String(modified.timeIntervalSince1970),
            String(Self.schemaVersion),
            String(analysis.sampleRate),
            String(analysis.minBPM),
            String(analysis.maxBPM),
            String(analysis.phraseBars),
            String(analysis.waveformPointsPerSecond),
            String(needsKey),
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(digest).plist")
    }
}
