import AppKit
import CoreServices
import MADSETCore
import Observation
import UniformTypeIdentifiers

/// The sets folder and what is in it, shared by every window and kept current while files change on disk.
@MainActor
@Observable
final class SetLibraryModel {
    static let shared = SetLibraryModel()

    let folder: URL
    private(set) var items: [SetLibrary.Item] = []
    /// The last operation that failed, until it is shown.
    var error: String?

    @ObservationIgnored private var watcher: FolderWatcher?
    private static let config = AppConfig.current.library
    /// Stands for the set in the frontmost window while it isn't in the library, so it can be dragged in.
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
    }

    func reload() {
        do {
            items = try SetLibrary.items(in: folder)
        } catch {
            items = []
            self.error = error.localizedDescription
        }
    }

    /// Opens a set in its window, bringing it forward if it is open already.
    func open(_ url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { Task { @MainActor in self.error = error.localizedDescription } }
        }
    }

    /// Moves the sets and groups among `urls` that are in the library into `group`, and saves the
    /// frontmost window's set there if it is among them.
    @discardableResult
    func drop(_ urls: [URL], into group: URL) -> Bool {
        let inLibrary = urls.filter(contains)
        perform { for url in inLibrary { _ = try SetLibrary.move(url, into: group) } }
        if urls.contains(Self.currentSet) { saveCurrentSet(in: group) }
        return !inLibrary.isEmpty || urls.contains(Self.currentSet)
    }

    /// Makes a group in `group` (or the library) and returns it so it can be named.
    func createGroup(in group: URL) -> SetLibrary.Item? {
        var created: URL?
        perform { created = try SetLibrary.createGroup(named: String(localized: "New Group"), in: group) }
        return created.map { SetLibrary.Item(url: $0, children: []) }
    }

    /// Makes an empty set in `group` and opens it.
    func createSet(in group: URL) {
        var created: URL?
        perform {
            let empty = try SetFile(bpm: nil, entries: []).encoded()
            created = try SetLibrary.createSet(named: String(localized: "New Set"), contents: empty, in: group)
        }
        if let created { open(created) }
    }

    /// Saves the set in the frontmost window into `group`, under its name, and keeps editing it there.
    func saveCurrentSet(in group: URL) {
        guard let document = NSDocumentController.shared.currentDocument else { return }
        let name = document.fileURL?.deletingPathExtension().lastPathComponent ?? document.displayName!
        var destination: URL?
        perform { destination = try SetLibrary.newSetURL(named: name, in: group) }
        guard let destination else { return }
        document.save(to: destination, ofType: document.fileType ?? UTType.madsetSet.identifier, for: .saveAsOperation) { error in
            Task { @MainActor in
                if let error { self.error = error.localizedDescription }
                self.reload()
            }
        }
    }

    /// Dissolves groups, deepest first, keeping every set in them.
    func ungroup(_ urls: [URL]) {
        let groups = urls.filter(contains).sorted { $0.pathComponents.count > $1.pathComponents.count }
        perform { for group in groups { try SetLibrary.ungroup(group) } }
    }

    /// Moves sets to the Trash, where they can be put back from.
    func trash(_ urls: [URL]) {
        perform { for url in urls.filter(contains) { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } }
    }

    func rename(_ url: URL, to name: String) {
        perform { _ = try SetLibrary.rename(url, to: name) }
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
