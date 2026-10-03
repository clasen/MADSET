import Foundation

/// Decoded tracks for playback, decoded in the background ahead of need and kept in a small LRU.
public final class SourceCache: @unchecked Sendable {
    private enum Slot {
        case loading
        case ready(PCMBuffer)
        case failed(any Error)
    }

    private let condition = NSCondition()
    private var slots: [URL: Slot] = [:]
    private var recency: [URL] = []
    private let capacity: Int
    private let sampleRate: Double
    private let decode: @Sendable (URL, Double) throws -> PCMBuffer

    public init(capacity: Int, sampleRate: Double, decode: @escaping @Sendable (URL, Double) throws -> PCMBuffer = AudioDecoder.decodeStereo) {
        precondition(capacity > 0, "Source cache needs room for at least one track")
        self.capacity = capacity
        self.sampleRate = sampleRate
        self.decode = decode
    }

    /// Starts decoding `url` in the background unless it is cached or already loading.
    public func prefetch(_ url: URL) {
        condition.lock()
        defer { condition.unlock() }
        guard slots[url] == nil else { return touch(url) }
        slots[url] = .loading
        touch(url)
        DispatchQueue.global(qos: .userInitiated).async { [self] in load(url) }
    }

    /// The decoded track, waiting for (or doing) the decode if needed.
    public func buffer(for url: URL) throws -> PCMBuffer {
        condition.lock()
        if slots[url] == nil {
            slots[url] = .loading
            touch(url)
            condition.unlock()
            load(url)
            condition.lock()
        }
        defer { condition.unlock() }
        while true {
            switch slots[url] {
            case .ready(let buffer):
                touch(url)
                return buffer
            case .failed(let error):
                throw error
            case .loading:
                condition.wait()
            case nil:
                preconditionFailure("Slot for \(url.lastPathComponent) was evicted while loading")
            }
        }
    }

    private func load(_ url: URL) {
        let result = Result { try decode(url, sampleRate) }
        condition.lock()
        switch result {
        case .success(let buffer): slots[url] = .ready(buffer)
        case .failure(let error): slots[url] = .failed(error)
        }
        evictIfNeeded()
        condition.broadcast()
        condition.unlock()
    }

    /// Requires the lock.
    private func touch(_ url: URL) {
        recency.removeAll { $0 == url }
        recency.append(url)
    }

    /// Requires the lock. Never evicts tracks still loading.
    private func evictIfNeeded() {
        while recency.count > capacity, let victim = recency.first(where: { if case .loading = slots[$0] { false } else { true } }) {
            recency.removeAll { $0 == victim }
            slots[victim] = nil
        }
    }
}
