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
/// Every arrangement edit goes through `perform`, which registers undo. The set saves itself to
/// `fileURL` shortly after every change, and at once on `close()`.
@MainActor
@Observable
final class SetDocument {
    /// Where the set is saved; follows the file when it is renamed or moved.
    var fileURL: URL
    private(set) var tracks: [Track] = [] {
        didSet { storeSaved() }
    }
    /// Tempo of the set; nil follows the tracks (median tempo).
    private(set) var tempo: Double? {
        didSet { storeSaved() }
    }
    /// Selected tracks, shared by the list and the timeline.
    var selection: Set<Track.ID> = []
    private(set) var isPlaying = false
    /// Tracks under the playhead, playing or paused.
    private(set) var nowPlaying: Set<Track.ID> = []
    private(set) var playbackError: String?
    /// Fraction done of the running export; nil when none is running.
    private(set) var exportProgress: Double?
    private(set) var exportError: String?
    /// An import that repeats songs already in the set, waiting for the user to skip or keep them.
    private(set) var pendingImport: PendingImport?
    private(set) var saveError: String?

    @ObservationIgnored private var queue: Task<Void, Never>?
    @ObservationIgnored private var player: SetPlayer?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    /// The window's undo manager; edits register here.
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

    /// The file as it was opened, then as last saved.
    @ObservationIgnored private var saved: SetFile

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        saved = try SetFile.decode(Data(contentsOf: fileURL))
    }

    /// Loads the saved arrangement and analyzes its tracks. Called once, when the set is shown.
    func start() {
        guard !started else { return }
        started = true
        tracks = saved.entries.map(Track.init(entry:))
        tempo = saved.bpm
        process(tracks.map(\.id))
    }

    /// Saves any pending change and stops playback and export, before another set is shown or the app quits.
    func close() {
        saveNow()
        player?.pause()
        isPlaying = false
        cancelExport()
        undoManager?.removeAllActions()
    }

    func saveNow() {
        saveTask?.cancel()
        save(current)
    }

    func clearSaveError() { saveError = nil }

    private var current: SetFile { SetFile(bpm: tempo, entries: tracks.map(\.entry)) }

    /// Saves after the arrangement has been still for a moment, so a drag writes once.
    private func storeSaved() {
        guard started, current != saved else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(Self.config.library.saveDelay))
            guard !Task.isCancelled else { return }
            save(current)
        }
    }

    private func save(_ file: SetFile) {
        guard file != saved else { return }
        do {
            try file.encoded().write(to: fileURL, options: .atomic)
            saved = file
        } catch {
            saveError = error.localizedDescription
        }
    }

    // MARK: - Derived state

    var effectiveTempo: Double {
        tempo ?? SetLayout.suggestedBPM(tracks.compactMap(\.bpm)) ?? Self.config.playback.emptySetBPM
    }

    var layout: SetLayout { Self.layout(of: tracks, bpm: effectiveTempo) }

    /// The layout `edit` would produce, to preview it while it is being made.
    func layout(applying edit: ArrangementEdit) -> SetLayout {
        Self.layout(of: Self.applying(edit, to: tracks), bpm: effectiveTempo)
    }

    private static func layout(of tracks: [Track], bpm: Double) -> SetLayout {
        SetLayout(
            bpm: bpm,
            entries: tracks.map(\.entry),
            tracks: Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0.layoutInfo) }),
            phraseBars: config.analysis.phraseBars
        )
    }

    var pendingCount: Int { tracks.filter(\.isPending).count }

    // MARK: - Editing

    /// Adds the audio files among `urls` (folders are expanded) at `index`, or at the end of the set,
    /// and analyzes them. When some repeat a song already in the set, `pendingImport` asks what to do.
    func importItems(_ urls: [URL], at index: Int? = nil) {
        Task {
            let files = await Self.audioFiles(in: urls)
            guard !files.isEmpty else { return }
            let read = await Self.readingTags(files.map { Track(entry: SetEntry(file: $0)) })
            let duplicates = DuplicateSongs.indices(of: read.map(\.song), among: tracks.map(\.song))
            if duplicates.isEmpty {
                insert(read, at: index)
            } else {
                pendingImport = PendingImport(tracks: read, duplicates: Set(duplicates.map { read[$0].id }), index: index)
            }
        }
    }

    /// Finishes the import waiting on the user, with or without the songs already in the set.
    func resolveImport(skippingDuplicates: Bool) {
        guard let pending = pendingImport else { return }
        pendingImport = nil
        insert(skippingDuplicates ? pending.tracks.filter { !pending.duplicates.contains($0.id) } : pending.tracks, at: pending.index)
    }

    func cancelImport() { pendingImport = nil }

    private func insert(_ added: [Track], at index: Int?) {
        guard !added.isEmpty else { return }
        perform(String(localized: "Import")) { document in
            document.tracks.insert(contentsOf: added, at: min(index ?? document.tracks.count, document.tracks.count))
        }
        process(added.map(\.id))
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        perform(String(localized: "Reorder")) { $0.tracks.move(fromOffsets: source, toOffset: destination) }
    }

    /// Moves `ids` right before `target`, or to the end when `target` is nil, keeping their order.
    func move(_ ids: Set<Track.ID>, before target: Track.ID?) {
        let source = IndexSet(tracks.indices.filter { ids.contains(tracks[$0].id) })
        guard !source.isEmpty, target.map({ !ids.contains($0) }) ?? true else { return }
        let destination = target.flatMap { t in tracks.firstIndex { $0.id == t } } ?? tracks.count
        var moved = tracks
        moved.move(fromOffsets: source, toOffset: destination)
        guard moved.map(\.id) != tracks.map(\.id) else { return }
        perform(String(localized: "Reorder")) { $0.tracks = moved }
    }

    /// Moves `ids` to the start of the set, keeping their order.
    func moveToStart(_ ids: Set<Track.ID>) {
        move(ids, before: tracks.first { !ids.contains($0.id) }?.id)
    }

    /// Splits an analyzed track at one of its own bars into two that play one after the other and
    /// from then on arrange like two tracks. The second part is selected.
    func split(_ id: Track.ID, atBar bar: Int) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        precondition(tracks[index].status == .ready, "Only analyzed tracks can be split")
        var second = tracks[index]
        perform(String(localized: "Split Track")) { document in
            second.entry = document.tracks[index].entry.split(atBar: bar)
            document.tracks.insert(second, at: index + 1)
        }
        selection = [second.id]
    }

    func remove(_ ids: Set<Track.ID>) {
        guard tracks.contains(where: { ids.contains($0.id) }) else { return }
        perform(ids.count == 1 ? String(localized: "Remove Track") : String(localized: "Remove Tracks")) { $0.tracks.removeAll { ids.contains($0.id) } }
        selection.subtract(ids)
    }

    func setTempo(_ bpm: Double?) {
        perform(String(localized: "Change Tempo")) { $0.tempo = bpm.map { min(max($0, 60), 200) } }
    }

    /// Changes one transition or cue setting of a track; nil returns it to automatic.
    func edit(_ id: Track.ID, _ name: String, _ change: @escaping (inout SetEntry) -> Void) {
        apply(ArrangementEdit(name: name, changes: [(id, change)]))
    }

    func apply(_ edit: ArrangementEdit) {
        perform(edit.name) { $0.tracks = Self.applying(edit, to: $0.tracks) }
    }


    private static func applying(_ edit: ArrangementEdit, to tracks: [Track]) -> [Track] {
        var tracks = tracks
        for (id, change) in edit.changes {
            if let index = tracks.firstIndex(where: { $0.id == id }) { change(&tracks[index].entry) }
        }
        return tracks
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
            do {
                try player.play()
            } catch {
                playbackError = error.localizedDescription
            }
        }
        isPlaying = player.isPlaying
    }

    func seek(to time: TimeInterval) {
        ensurePlayer()?.seek(to: min(max(0, time), layout.duration))
    }

    /// Seconds into the set at the playhead.
    var currentTime: TimeInterval { player?.currentTime ?? 0 }

    /// Follows the playhead and stops at the end of the set. Called by the transport while it polls the playhead.
    func playbackTick() {
        let layout = layout
        let bar = layout.bar(atTime: currentTime)
        let current = Set(layout.entries.filter { Double($0.startBar) <= bar && bar < Double($0.endBar) }.map(\.id))
        if current != nowPlaying { nowPlaying = current }
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

    // MARK: - Export

    /// Whether the whole set can be rendered: every track is analyzed and no export is running.
    var canExport: Bool { !tracks.isEmpty && pendingCount == 0 && exportProgress == nil }

    /// Asks where to save, then renders the set into an audio file in the background.
    func exportMix(as format: SetExporter.Format) {
        guard canExport, let url = ExportPanel.choose(format) else { return }
        let layout = layout
        exportProgress = 0
        exportTask = Task {
            do {
                try await Self.export(layout, format: format, to: url, sources: Self.sources, config: Self.config) { fraction in
                    Task { @MainActor in if self.exportProgress != nil { self.exportProgress = fraction } }
                }
            } catch is CancellationError {
            } catch {
                exportError = error.localizedDescription
            }
            exportProgress = nil
            exportTask = nil
        }
    }

    func cancelExport() { exportTask?.cancel() }

    func clearExportError() { exportError = nil }

    /// Reports progress only when it changes by a tenth of a percent, to keep the main actor free.
    @concurrent
    private static func export(
        _ layout: SetLayout, format: SetExporter.Format, to url: URL, sources: SourceCache, config: AppConfig,
        report: @escaping @Sendable (Double) -> Void
    ) async throws {
        var reported = -1
        try SetExporter.export(layout, format: format, to: url, sources: sources, playback: config.playback, config: config.export) { fraction in
            try Task.checkCancellation()
            let permille = Int(fraction * 1000)
            if permille != reported {
                reported = permille
                report(fraction)
            }
        }
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
        let jobs = ids.compactMap { id in tracks.first { $0.id == id && $0.status == .reading }.map { (id: id, url: $0.url) } }
        var batch = UpdateBatch()
        await forEachConcurrently(jobs, limit: Self.config.analysis.maxConcurrentTracks, operation: { job in
            await Result { try await AnalysisPipeline.readTags(url: job.url) }
        }, onResult: { job, result in
            batch.add(job.id) { Self.apply(result, to: &$0) }
            if batch.isDue { apply(&batch) }
        })
        apply(&batch)
    }

    /// `tracks` with their tags read, in the same order.
    private static func readingTags(_ tracks: [Track]) async -> [Track] {
        var read = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        await forEachConcurrently(tracks, limit: config.analysis.maxConcurrentTracks, operation: { track in
            await Result { try await AnalysisPipeline.readTags(url: track.url) }
        }, onResult: { track, result in
            apply(result, to: &read[track.id]!)
        })
        return tracks.map { read[$0.id]! }
    }

    private static func apply(_ result: Result<(tags: TrackTags, duration: TimeInterval), any Error>, to track: inout Track) {
        switch result {
        case .success(let read):
            track.tags = read.tags
            track.headerDuration = read.duration
            track.status = .analyzing
        case .failure(let error):
            track.status = .failed(describe(error))
        }
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

/// Imported tracks, with their tags read, some of which repeat songs already in the set.
struct PendingImport {
    let tracks: [Track]
    let duplicates: Set<Track.ID>
    let index: Int?
}

/// A change to some entries of the set, made as one undoable step.
struct ArrangementEdit {
    let name: String
    let changes: [(Track.ID, (inout SetEntry) -> Void)]

    /// Makes `entry` start at `bar` of the previous track, keeping the transition's length.
    static func mixIn(of entry: PlacedEntry, after previous: PlacedEntry, atBar bar: Int) -> ArrangementEdit {
        let cueOut = entry.previousCueOut(mixingInAt: bar, after: previous)
        let overlap = entry.overlapBars
        return ArrangementEdit(name: String(localized: "Move Transition"), changes: [
            (previous.id, { $0.cueOutBar = cueOut }),
            (entry.id, { $0.overlapBars = overlap }),
        ])
    }
}

extension ArrangementEdit {
    /// Makes the transition into `entry` `length` bars long around where it is, moving neither track.
    static func resizeTransition(of entry: PlacedEntry, after previous: PlacedEntry, to length: Int) -> ArrangementEdit {
        let resized = entry.resizingTransition(to: length, after: previous)
        return ArrangementEdit(name: String(localized: "Change Transition"), changes: [
            (previous.id, { $0.cueOutBar = resized.previousCueOut }),
            (entry.id, {
                $0.cueInBar = resized.cueIn
                $0.overlapBars = resized.overlap
                $0.bassSwapBar = resized.bassSwap
            }),
        ])
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
