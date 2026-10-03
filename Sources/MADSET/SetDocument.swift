import Combine
import Foundation
import MADSETCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let madsetSet = UTType(exportedAs: "com.martinclasen.madset.set")
}

/// A set being built: track order, transitions, tempo, the analysis queue and playback.
/// Every arrangement edit goes through `perform`, which registers undo (and so marks the document edited).
@MainActor
@Observable
final class SetDocument: ReferenceFileDocument {
    nonisolated static let readableContentTypes: [UTType] = [.madsetSet]

    private(set) var tracks: [Track] = []
    /// Tempo of the set; nil follows the tracks (median tempo).
    private(set) var tempo: Double?
    var selection: Track.ID?
    private(set) var isPlaying = false
    private(set) var playbackError: String?

    @ObservationIgnored private var queue: Task<Void, Never>?
    @ObservationIgnored private var player: SetPlayer?
    @ObservationIgnored private var started = false
    /// The window's undo manager; edits register here, which also marks the document as edited.
    @ObservationIgnored weak var undoManager: UndoManager?

    /// Analysis and decoded audio are shared by every open set.
    private static let config = AppConfig.current
    private static let pipeline: AnalysisPipeline = {
        do {
            return AnalysisPipeline(config: config.analysis, cache: try AnalysisCache.userCaches(config: config))
        } catch {
            fatalError("Could not open the analysis cache: \(error)")
        }
    }()
    private static let sources = SourceCache(capacity: config.playback.cachedSources, sampleRate: config.playback.sampleRate)

    /// The file this document was opened from; its arrangement is applied by `start()` on the main actor.
    private nonisolated let opened: SetFile?

    nonisolated init() {
        opened = nil
    }

    nonisolated init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        opened = try SetFile.decode(data)
    }

    nonisolated func snapshot(contentType: UTType) throws -> SetFile {
        MainActor.assumeIsolated {
            started ? SetFile(bpm: tempo, entries: tracks.map(\.entry)) : opened ?? SetFile(bpm: nil, entries: [])
        }
    }

    nonisolated func fileWrapper(snapshot: SetFile, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try snapshot.encoded())
    }

    /// Loads the opened arrangement and analyzes its tracks. Called once when the window appears.
    func start() {
        guard !started else { return }
        started = true
        guard let opened else { return }
        tracks = opened.entries.map(Track.init(entry:))
        tempo = opened.bpm
        process(tracks.map(\.id))
    }

    // MARK: - Derived state

    var effectiveTempo: Double {
        tempo ?? SetLayout.suggestedBPM(tracks.compactMap(\.bpm)) ?? Self.config.playback.emptySetBPM
    }

    var layout: SetLayout {
        SetLayout(
            bpm: effectiveTempo,
            entries: tracks.map(\.entry),
            tracks: Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0.layoutInfo) }),
            phraseBars: Self.config.analysis.phraseBars
        )
    }

    var pendingCount: Int { tracks.filter(\.isPending).count }

    // MARK: - Editing

    /// Adds the audio files among `urls` (folders are expanded) at `index`, or at the end of the set,
    /// and analyzes them. Files already in the set are skipped.
    func importItems(_ urls: [URL], at index: Int? = nil) {
        Task {
            let files = await Self.audioFiles(in: urls)
            var known = Set(tracks.map(\.url.standardizedFileURL))
            let added = files.compactMap { url -> Track? in
                known.insert(url.standardizedFileURL).inserted ? Track(entry: SetEntry(file: url)) : nil
            }
            guard !added.isEmpty else { return }
            perform(String(localized: "Import")) { document in
                document.tracks.insert(contentsOf: added, at: min(index ?? document.tracks.count, document.tracks.count))
            }
            process(added.map(\.id))
        }
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        perform(String(localized: "Reorder")) { $0.tracks.move(fromOffsets: source, toOffset: destination) }
    }

    /// Moves a track right before `target`, or to the end when `target` is nil.
    func move(_ id: Track.ID, before target: Track.ID?) {
        guard id != target, tracks.contains(where: { $0.id == id }) else { return }
        perform(String(localized: "Reorder")) { document in
            let from = document.tracks.firstIndex { $0.id == id }!
            let track = document.tracks.remove(at: from)
            let index = target.flatMap { t in document.tracks.firstIndex { $0.id == t } } ?? document.tracks.count
            document.tracks.insert(track, at: index)
        }
    }

    func remove(_ id: Track.ID) {
        perform(String(localized: "Remove Track")) { $0.tracks.removeAll { $0.id == id } }
        if selection == id { selection = nil }
    }

    func setTempo(_ bpm: Double?) {
        perform(String(localized: "Change Tempo")) { $0.tempo = bpm.map { min(max($0, 60), 200) } }
    }

    /// Changes one transition or cue setting of a track; nil returns it to automatic.
    func edit(_ id: Track.ID, _ name: String, _ change: @escaping (inout SetEntry) -> Void) {
        perform(name) { document in
            guard let index = document.tracks.firstIndex(where: { $0.id == id }) else { return }
            change(&document.tracks[index].entry)
        }
    }

    // MARK: - Undo

    /// The part of the document that undo restores. Analysis results are not part of it.
    private struct Arrangement {
        let tracks: [Track]
        let tempo: Double?
    }

    private func perform(_ name: String, _ change: (SetDocument) -> Void) {
        let before = Arrangement(tracks: tracks, tempo: tempo)
        change(self)
        registerUndo(restoring: before, name: name, undoManager)
        syncPlayer()
    }

    private func registerUndo(restoring arrangement: Arrangement, name: String, _ undoManager: UndoManager?) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated {
                let current = Arrangement(tracks: document.tracks, tempo: document.tempo)
                document.restore(arrangement)
                document.registerUndo(restoring: current, name: name, undoManager)
            }
        }
        undoManager.setActionName(name)
    }

    /// Restores order, transitions and tempo, keeping the newest analysis of every track.
    private func restore(_ arrangement: Arrangement) {
        let live = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        tempo = arrangement.tempo
        tracks = arrangement.tracks.map { saved in
            guard var current = live[saved.id] else { return saved }
            current.entry = saved.entry
            return current
        }
        let stale = tracks.filter { $0.isPending && live[$0.id] == nil }.map(\.id)
        if !stale.isEmpty { process(stale) }
        syncPlayer()
    }

    // MARK: - Playback

    func togglePlayback() {
        guard let player = ensurePlayer() else { return }
        if player.isPlaying {
            player.pause()
        } else {
            if player.currentTime >= layout.duration { player.seek(to: 0) }
            player.play()
        }
        isPlaying = player.isPlaying
    }

    func seek(to time: TimeInterval) {
        ensurePlayer()?.seek(to: min(max(0, time), layout.duration))
    }

    /// Seconds into the set at the playhead.
    var currentTime: TimeInterval { player?.currentTime ?? 0 }

    /// Stops at the end of the set. Called by the transport while it polls the playhead.
    func playbackTick() {
        guard let player, player.isPlaying, player.currentTime >= layout.duration else { return }
        player.pause()
        isPlaying = false
    }

    func clearPlaybackError() { playbackError = nil }

    @discardableResult
    private func ensurePlayer() -> SetPlayer? {
        if let player { return player }
        do {
            let player = try SetPlayer(config: Self.config.playback, sources: Self.sources)
            player.load(layout)
            self.player = player
            return player
        } catch {
            playbackError = error.localizedDescription
            return nil
        }
    }

    private func syncPlayer() {
        player?.load(layout)
    }

    // MARK: - Analysis

    @concurrent
    private static func audioFiles(in urls: [URL]) async -> [URL] {
        AudioFileScanner.audioFiles(in: urls)
    }

    /// Reads tags, then analyzes. Batches run one after another so the concurrency limit holds.
    private func process(_ ids: [Track.ID]) {
        let previous = queue
        queue = Task {
            await previous?.value
            await readTags(ids)
            await analyze(ids)
        }
    }

    private func readTags(_ ids: [Track.ID]) async {
        let jobs = ids.compactMap { id in tracks.first { $0.id == id }.map { (id: id, url: $0.url) } }
        var batch = UpdateBatch()
        await forEachConcurrently(jobs, limit: Self.config.analysis.maxConcurrentTracks, operation: { job in
            await Result { try await AnalysisPipeline.readTags(url: job.url) }
        }, onResult: { job, result in
            batch.add(job.id) { track in
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
        let pipeline = Self.pipeline
        var batch = UpdateBatch()
        await forEachConcurrently(jobs, limit: Self.config.analysis.maxConcurrentTracks, operation: { job in
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
        case BeatTracker.Failure.noRhythmicContent: String(localized: "No rhythm found (a track without kick, or silence?)")
        case AudioDecoderError.unsupportedFormat: String(localized: "Unsupported audio format")
        case AudioDecoderError.conversionFailed(_, let reason): String(localized: "Could not decode: \(reason)")
        case TagReaderError.unreadable: String(localized: "Could not open the file")
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
        syncPlayer()
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
