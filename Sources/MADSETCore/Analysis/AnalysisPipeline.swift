import Foundation

/// Analysis with caching, run off the caller's actor.
public struct AnalysisPipeline: Sendable {
    public struct Outcome: Sendable {
        public let analysis: TrackAnalysis
        public let fromCache: Bool
    }

    public let config: AppConfig.Analysis
    public let cache: AnalysisCache?

    public init(config: AppConfig.Analysis, cache: AnalysisCache?) {
        self.config = config
        self.cache = cache
    }

    @concurrent
    public func analyze(url: URL, needsKey: Bool) async throws -> Outcome {
        if let cached = try cache?.load(for: url, needsKey: needsKey) {
            return Outcome(analysis: cached, fromCache: true)
        }
        let analysis = try TrackAnalyzer.analyze(url: url, needsKey: needsKey, config: config)
        try cache?.store(analysis, for: url, needsKey: needsKey)
        return Outcome(analysis: analysis, fromCache: false)
    }

    @concurrent
    public static func readTags(url: URL) async throws -> (tags: TrackTags, duration: TimeInterval) {
        (try MIKTags.read(url: url), try AudioDecoder.duration(url: url))
    }
}

/// Runs `operation` over `items` with at most `limit` in flight, reporting each result as it finishes.
/// `onResult` runs on the caller's actor.
nonisolated(nonsending)
public func forEachConcurrently<Item: Sendable, Output: Sendable>(
    _ items: [Item],
    limit: Int,
    operation: @escaping @Sendable (Item) async -> Output,
    onResult: (Item, Output) async -> Void
) async {
    precondition(limit > 0, "Concurrency limit must be positive")
    await withTaskGroup(of: (Item, Output).self) { group in
        var iterator = items.makeIterator()
        for _ in 0..<limit {
            guard let item = iterator.next() else { break }
            group.addTask { (item, await operation(item)) }
        }
        while let (item, output) = await group.next() {
            await onResult(item, output)
            if let next = iterator.next() {
                group.addTask { (next, await operation(next)) }
            }
        }
    }
}
