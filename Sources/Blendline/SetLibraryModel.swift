import AppKit
import CoreServices
import BlendlineCore
import Observation
import UniformTypeIdentifiers

/// The sets folder and what is in it, kept current while files change on disk, like the playlists
/// of a DJ app: one set is loaded into the timeline and decks, and the track list browses any set
/// without touching what plays. Open sets follow their files when they are renamed or moved.
@MainActor
@Observable
final class SetLibraryModel {
    static let shared = SetLibraryModel()

    let folder: URL
    private(set) var items: [SetLibrary.Item] = []
    /// The set in the timeline and decks.
    private(set) var loaded: SetDocument?
    /// The set in the track list; the loaded one or another.
    private(set) var browsed: SetDocument?
    /// The last operation that failed, until it is shown.
    var error: String?

    @ObservationIgnored private var watcher: FolderWatcher?
    private static let config = AppConfig.current.library
    private static let lastSetKey = "lastSet"
    /// Stands for the loaded set while it isn't in the library, so it can be dragged in.
    static let loadedSet = URL(string: "blendline:loaded-set")!

    private init() {
        do {
            let music = try FileManager.default.url(for: .musicDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            folder = music.appending(component: Self.config.folderName, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            fatalError("Could not open the sets folder: \(error)")
        }
        watcher = FolderWatcher(folder: folder, latency: Self.config.watchLatency) { [weak self] in self?.reload() }
        reload()
        let last = UserDefaults.standard.string(forKey: Self.lastSetKey).map { URL(filePath: $0) }
        if let last, FileManager.default.fileExists(atPath: last.path) { load(last) } else { loadAnySet() }
    }

    func reload() {
        do {
            items = try SetLibrary.items(in: folder)
        } catch {
            items = []
            self.error = error.localizedDescription
        }
    }

    /// Shows the set at `url` in the track list; what plays stays as it is.
    func browse(_ url: URL) {
        if let loaded, Self.same(url, loaded.fileURL) { return replaceBrowsed(with: loaded) }
        guard browsed.map({ !Self.same(url, $0.fileURL) }) ?? true else { return }
        do {
            let document = try SetDocument(fileURL: url)
            document.start()
            replaceBrowsed(with: document)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Puts the set at `url` in the timeline and decks, and in the track list.
    func load(_ url: URL) {
        browse(url)
        guard let browsed, browsed !== loaded else { return }
        loaded?.close()
        loaded = browsed
        remember()
    }

    /// Asks for a set file anywhere and loads it.
    func loadChosenSet() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.blendlineSet]
        panel.directoryURL = folder
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    /// Handles a drop on a set or group, or on the library itself when `target` is nil:
    /// - sets and groups of the library move into the group (a set's group, when dropped on a set);
    /// - the loaded set, when it is outside the library, is copied in and loaded from there;
    /// - audio files and folders from elsewhere are added to the set they are dropped on.
    @discardableResult
    func drop(_ urls: [URL], onto target: SetLibrary.Item?) -> Bool {
        let group = target.map { $0.isGroup ? $0.url : $0.url.deletingLastPathComponent() } ?? folder
        let inLibrary = urls.filter(contains)
        let tracks = AudioFileScanner.audioFiles(in: urls.filter { !contains($0) && $0.isFileURL })
        perform {
            for url in inLibrary { follow(url, to: try SetLibrary.move(url, into: group)) }
            if urls.contains(Self.loadedSet), let loaded {
                loaded.saveNow()
                let copy = try SetLibrary.newSetURL(named: loaded.fileURL.deletingPathExtension().lastPathComponent, in: group)
                try FileManager.default.copyItem(at: loaded.fileURL, to: copy)
                follow(loaded.fileURL, to: copy)
            }
        }
        if let target, !target.isGroup, !tracks.isEmpty { addTracks(tracks, to: target.url) }
        return !inLibrary.isEmpty || urls.contains(Self.loadedSet) || (target?.isGroup == false && !tracks.isEmpty)
    }

    /// Makes a group in `group` (or the library) and returns it so it can be named.
    func createGroup(in group: URL) -> SetLibrary.Item? {
        var created: URL?
        perform { created = try SetLibrary.createGroup(named: String(localized: "New Group"), in: group) }
        return created.map { SetLibrary.Item(url: $0, children: []) }
    }

    /// Makes an empty set in `group` and browses it.
    func createSet(in group: URL) {
        var created: URL?
        perform {
            let empty = try SetFile(bpm: nil, entries: []).encoded()
            created = try SetLibrary.createSet(named: SetName.random(), contents: empty, in: group)
        }
        if let created { browse(created) }
    }

    /// Dissolves groups, deepest first, keeping every set in them.
    func ungroup(_ urls: [URL]) {
        let groups = urls.filter(contains).sorted { $0.pathComponents.count > $1.pathComponents.count }
        perform {
            for group in groups {
                for move in try SetLibrary.ungroup(group) { follow(move.from, to: move.to) }
            }
        }
    }

    /// Moves sets to the Trash, where they can be put back from. An open set that goes is replaced.
    func trash(_ urls: [URL]) {
        let trashed = urls.filter(contains)
        for document in openDocuments { document.saveNow() }
        perform { for url in trashed { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } }
        if let loaded, !FileManager.default.fileExists(atPath: loaded.fileURL.path) { loadAnySet() }
        if let browsed, !FileManager.default.fileExists(atPath: browsed.fileURL.path), let loaded { replaceBrowsed(with: loaded) }
    }

    /// Saves and closes the open sets before the app quits.
    func closeAll() {
        for document in openDocuments { document.close() }
    }

    func rename(_ url: URL, to name: String) {
        perform { follow(url, to: try SetLibrary.rename(url, to: name)) }
    }

    /// Whether `url` is a set or group inside the library.
    func contains(_ url: URL) -> Bool {
        let root = folder.standardizedFileURL.pathComponents
        let path = url.standardizedFileURL.pathComponents
        return path.count > root.count && path.starts(with: root)
    }

    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
        } catch SetLibrary.Failure.groupIntoItself {
            error = String(localized: "A group can't go inside itself.")
        } catch SetLibrary.Failure.invalidName(let name) {
            error = String(localized: "“\(name)” can't be used as a name.")
        } catch {
            self.error = error.localizedDescription
        }
        reload()
    }

    private var openDocuments: [SetDocument] {
        guard let browsed, browsed !== loaded else { return [loaded].compactMap(\.self) }
        return [loaded, browsed].compactMap(\.self)
    }

    private func replaceBrowsed(with document: SetDocument) {
        guard document !== browsed else { return }
        if let browsed, browsed !== loaded { browsed.close() }
        browsed = document
    }

    /// Adds tracks to a set, through the open document when the set is open.
    private func addTracks(_ files: [URL], to set: URL) {
        if let document = openDocuments.first(where: { Self.same($0.fileURL, set) }) {
            document.importItems(files)
        } else {
            perform { try SetLibrary.addTracks(files, toSetAt: set) }
        }
    }

    /// Points open sets at their new place when they, or a group they are in, moved from `old` to `new`.
    private func follow(_ old: URL, to new: URL) {
        let from = old.standardizedFileURL.pathComponents
        for document in openDocuments {
            let path = document.fileURL.standardizedFileURL.pathComponents
            guard path.starts(with: from) else { continue }
            document.fileURL = path.dropFirst(from.count).reduce(new) { $0.appending(component: $1) }
        }
        remember()
    }

    private func remember() {
        UserDefaults.standard.set(loaded?.fileURL.path, forKey: Self.lastSetKey)
    }

    private static func same(_ a: URL, _ b: URL) -> Bool { a.standardizedFileURL == b.standardizedFileURL }

    /// Loads the first set in the library, or a new one when there is none.
    private func loadAnySet() {
        func first(_ items: [SetLibrary.Item]) -> URL? {
            items.lazy.compactMap { $0.isGroup ? first($0.children ?? []) : $0.url }.first
        }
        if let url = first(items) {
            load(url)
        } else {
            createSet(in: folder)
            if let browsed { load(browsed.fileURL) }
        }
    }
}

/// Calls `onChange` on the main actor whenever something inside `folder` changes, at any depth.
/// Unchecked: `stream` is only touched in `init` and `deinit`, and events arrive on the main queue.
private final class FolderWatcher: @unchecked Sendable {
    private let onChange: @MainActor @Sendable () -> Void
    private var stream: FSEventStreamRef?

    init(folder: URL, latency: TimeInterval, onChange: @escaping @MainActor @Sendable () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info!).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.onChange() }
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, [folder.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else {
            preconditionFailure("Could not watch \(folder.path)")
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
