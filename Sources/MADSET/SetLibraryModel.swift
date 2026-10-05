import AppKit
import CoreServices
import MADSETCore
import Observation

/// The sets folder the user chose and what is in it, shared by every window and kept current
/// while files change on disk.
@MainActor
@Observable
final class SetLibraryModel {
    static let shared = SetLibraryModel()

    private(set) var folder: URL?
    private(set) var items: [SetLibrary.Item] = []
    /// The last operation that failed, until it is shown.
    var error: String?

    @ObservationIgnored private var watcher: FolderWatcher?
    private static let folderKey = "setsFolder"
    private static let config = AppConfig.current.library

    private init() {
        folder = UserDefaults.standard.url(forKey: Self.folderKey)
        watch()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = String(localized: "Use Folder")
        panel.message = String(localized: "Choose the folder that holds your sets. Its folders become groups.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url, forKey: Self.folderKey)
        folder = url
        watch()
    }

    func reload() {
        guard let folder else { return items = [] }
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

    /// Moves the sets and groups among `urls` that are in the library into `group`.
    @discardableResult
    func move(_ urls: [URL], into group: URL) -> Bool {
        let inLibrary = urls.filter(contains)
        perform { for url in inLibrary { _ = try SetLibrary.move(url, into: group) } }
        return !inLibrary.isEmpty
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

    func rename(_ url: URL, to name: String) {
        perform { _ = try SetLibrary.rename(url, to: name) }
    }

    /// Whether `url` is a set or group inside the library.
    func contains(_ url: URL) -> Bool {
        guard let folder else { return false }
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

    private func watch() {
        watcher = folder.map { FolderWatcher(folder: $0, latency: Self.config.watchLatency) { [weak self] in self?.reload() } }
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
