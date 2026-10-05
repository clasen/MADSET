import AppKit
import CoreServices
import MADSETCore
import Observation
import UniformTypeIdentifiers

/// The sets folder, what is in it (kept current while files change on disk) and the set the window
/// shows, which follows its file when it is renamed or moved.
@MainActor
@Observable
final class SetLibraryModel {
    static let shared = SetLibraryModel()

    let folder: URL
    private(set) var items: [SetLibrary.Item] = []
    /// The set on show.
    private(set) var current: SetDocument?
    /// The last operation that failed, until it is shown.
    var error: String?

    @ObservationIgnored private var watcher: FolderWatcher?
    private static let config = AppConfig.current.library
    private static let lastSetKey = "lastSet"
    /// Stands for the set on show while it isn't in the library, so it can be dragged in.
    static let currentSet = URL(string: "madset:current-set")!

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
        if let last, FileManager.default.fileExists(atPath: last.path) { show(last) } else { showAnySet() }
    }

    func reload() {
        do {
            items = try SetLibrary.items(in: folder)
        } catch {
            items = []
            self.error = error.localizedDescription
        }
    }

    /// Shows the set at `url` in the window instead of the one on show.
    func show(_ url: URL) {
        guard url.standardizedFileURL != current?.fileURL.standardizedFileURL else { return }
        do {
            let document = try SetDocument(fileURL: url)
            current?.close()
            current = document
            document.start()
            remember()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Asks for a set file anywhere and shows it.
    func showChosenSet() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.madsetSet]
        panel.directoryURL = folder
        if panel.runModal() == .OK, let url = panel.url { show(url) }
    }

    /// Moves the sets and groups among `urls` that are in the library into `group`; the set on show,
    /// when it is outside the library, is copied in and shown from there.
    @discardableResult
    func drop(_ urls: [URL], into group: URL) -> Bool {
        let inLibrary = urls.filter(contains)
        perform {
            for url in inLibrary { follow(url, to: try SetLibrary.move(url, into: group)) }
            if urls.contains(Self.currentSet), let current {
                current.saveNow()
                let copy = try SetLibrary.newSetURL(named: current.fileURL.deletingPathExtension().lastPathComponent, in: group)
                try FileManager.default.copyItem(at: current.fileURL, to: copy)
                follow(current.fileURL, to: copy)
            }
        }
        return !inLibrary.isEmpty || urls.contains(Self.currentSet)
    }

    /// Makes a group in `group` (or the library) and returns it so it can be named.
    func createGroup(in group: URL) -> SetLibrary.Item? {
        var created: URL?
        perform { created = try SetLibrary.createGroup(named: String(localized: "New Group"), in: group) }
        return created.map { SetLibrary.Item(url: $0, children: []) }
    }

    /// Makes an empty set in `group` and shows it.
    func createSet(in group: URL) {
        var created: URL?
        perform {
            let empty = try SetFile(bpm: nil, entries: []).encoded()
            created = try SetLibrary.createSet(named: String(localized: "New Set"), contents: empty, in: group)
        }
        if let created { show(created) }
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

    /// Moves sets to the Trash, where they can be put back from. If the set on show goes, another one is shown.
    func trash(_ urls: [URL]) {
        let trashed = urls.filter(contains)
        current?.saveNow()
        perform { for url in trashed { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } }
        if let current, !FileManager.default.fileExists(atPath: current.fileURL.path) { showAnySet() }
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

    /// Points the set on show at its new place when it, or a group it is in, moved from `old` to `new`.
    private func follow(_ old: URL, to new: URL) {
        guard let current else { return }
        let from = old.standardizedFileURL.pathComponents
        let path = current.fileURL.standardizedFileURL.pathComponents
        guard path.starts(with: from) else { return }
        current.fileURL = path.dropFirst(from.count).reduce(new) { $0.appending(component: $1) }
        remember()
    }

    private func remember() {
        UserDefaults.standard.set(current?.fileURL.path, forKey: Self.lastSetKey)
    }

    /// Shows the first set in the library, or a new one when there is none.
    private func showAnySet() {
        func first(_ items: [SetLibrary.Item]) -> URL? {
            items.lazy.compactMap { $0.isGroup ? first($0.children ?? []) : $0.url }.first
        }
        if let url = first(items) { show(url) } else { createSet(in: folder) }
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
