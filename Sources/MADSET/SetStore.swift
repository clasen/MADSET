import Foundation
import MADSETCore
import Observation

/// The set being built: track order, selection and the analysis queue.
@MainActor
@Observable
final class SetStore {
    private(set) var tracks: [Track] = []
    var selection: Track.ID?

    private let pipeline: AnalysisPipeline
    private let concurrency: Int
    @ObservationIgnored private var queue: Task<Void, Never>?

    init(config: AppConfig) throws {
        pipeline = AnalysisPipeline(config: config.analysis, cache: try AnalysisCache.userCaches(config: config))
        concurrency = config.analysis.maxConcurrentTracks
    }

    var totalDuration: TimeInterval { tracks.compactMap(\.duration).reduce(0, +) }
    var pendingCount: Int { tracks.filter { $0.status == .reading || $0.status == .analyzing }.count }

    /// Adds the audio files among `urls` (folders are expanded) to the end of the set and analyzes them.
    /// Imports run one after another so the analysis concurrency limit holds across drops.
    func importItems(_ urls: [URL]) {
        let previous = queue
        queue = Task {
            await previous?.value
            let files = await Self.audioFiles(in: urls)
            var known = Set(tracks.map(\.url.standardizedFileURL))
            let added = files.compactMap { url -> Track? in
                known.insert(url.standardizedFileURL).inserted ? Track(url: url) : nil
            }
            guard !added.isEmpty else { return }
            tracks += added
            await readTags(added.map(\.id))
            await analyze(added.map(\.id))
        }
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        tracks.move(fromOffsets: source, toOffset: destination)
    }

    /// Moves a track right before `target`, or to the end when `target` is nil.
    func move(_ id: Track.ID, before target: Track.ID?) {
        guard id != target, let from = tracks.firstIndex(where: { $0.id == id }) else { return }
        let track = tracks.remove(at: from)
        let index = target.flatMap { t in tracks.firstIndex { $0.id == t } } ?? tracks.count
        tracks.insert(track, at: index)
    }

    func remove(_ id: Track.ID) {
        tracks.removeAll { $0.id == id }
        if selection == id { selection = nil }
    }

    // MARK: - Pipeline

    @concurrent
    private static func audioFiles(in urls: [URL]) async -> [URL] {
        AudioFileScanner.audioFiles(in: urls)
    }

    private func readTags(_ ids: [Track.ID]) async {
        let jobs = ids.compactMap { id in tracks.first { $0.id == id }.map { (id, $0.url) } }
        var batch = UpdateBatch()
        await forEachConcurrently(jobs, limit: concurrency, operation: { job in
            await Result { try await AnalysisPipeline.readTags(url: job.1) }
        }, onResult: { job, result in
            batch.add(job.0) { track in
                switch result {
                case .success(let read):
                    track.tags = read.tags
                    track.headerDuration = read.duration
                    track.status = .analyzing
                case .failure(let error):
                    track.status = .failed(Self.describe(error))
                }
            }
            if batch.isDue { apply(&batch) }
        })
        apply(&batch)
    }

    private func analyze(_ ids: [Track.ID]) async {
        let jobs = ids.compactMap { id in
            tracks.first { $0.id == id && $0.status == .analyzing }.map { (id: id, url: $0.url, needsKey: $0.tags.key == nil) }
        }
        let pipeline = pipeline
        var batch = UpdateBatch()
        await forEachConcurrently(jobs, limit: concurrency, operation: { job in
            await Result { try await pipeline.analyze(url: job.url, needsKey: job.needsKey) }
        }, onResult: { job, result in
            batch.add(job.id) { track in
                switch result {
                case .success(let outcome):
                    track.analysis = outcome.analysis
                    track.status = .ready
                case .failure(let error):
                    track.status = .failed(Self.describe(error))
                }
            }
            if batch.isDue { apply(&batch) }
        })
        apply(&batch)
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case BeatTracker.Failure.noRhythmicContent: "No se encontró ritmo (¿tema sin kick o silencio?)"
        case AudioDecoderError.unsupportedFormat: "Formato de audio no soportado"
        case AudioDecoderError.conversionFailed(_, let reason): "No se pudo decodificar: \(reason)"
        case TagReaderError.unreadable: "No se pudo abrir el archivo"
        default: error.localizedDescription
        }
    }

    /// Applies the batched changes as one mutation, so the list and timeline redraw once per batch.
    private func apply(_ batch: inout UpdateBatch) {
        guard !batch.changes.isEmpty else { return }
        var updated = tracks
        for (id, change) in batch.changes {
            if let index = updated.firstIndex(where: { $0.id == id }) { change(&updated[index]) }
        }
        tracks = updated
        batch.reset()
    }
}

/// Results that arrive within `interval` are applied together.
private struct UpdateBatch {
    static let interval: Duration = .milliseconds(100)

    private(set) var changes: [(Track.ID, (inout Track) -> Void)] = []
    private var started = ContinuousClock.now

    var isDue: Bool { ContinuousClock.now - started >= Self.interval }

    mutating func add(_ id: Track.ID, _ change: @escaping (inout Track) -> Void) {
        if changes.isEmpty { started = .now }
        changes.append((id, change))
    }

    mutating func reset() { changes.removeAll() }
}

extension Result where Failure == any Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
