import Foundation

/// The sets (`.madset` files) under a folder, grouped by the folders they are in. Groups are plain
/// folders, so the library is whatever is on disk.
public enum SetLibrary {
    public static let fileExtension = "madset"

    public enum Failure: Error, Equatable {
        /// A group can't go inside itself or one of its own groups.
        case groupIntoItself
        case invalidName(String)
    }

    /// A set, or a group with the sets and groups inside it.
    public struct Item: Identifiable, Hashable, Sendable {
        public var url: URL
        /// What is inside a group; nil for a set.
        public var children: [Item]?

        public init(url: URL, children: [Item]?) {
            self.url = url
            self.children = children
        }

        public var id: URL { url }
        public var isGroup: Bool { children != nil }
        public var name: String { isGroup ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent }
    }

    /// The groups and sets in `folder`, groups first, each sorted by name the way Finder does.
    /// Hidden files and files that aren't sets are left out; empty groups are kept.
    public static func items(in folder: URL) throws -> [Item] {
        let contents = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        var groups: [Item] = []
        var sets: [Item] = []
        for url in contents {
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                groups.append(Item(url: url, children: try items(in: url)))
            } else if url.pathExtension.lowercased() == fileExtension {
                sets.append(Item(url: url, children: nil))
            }
        }
        let byName = { (a: Item, b: Item) in a.name.localizedStandardCompare(b.name) == .orderedAscending }
        return groups.sorted(by: byName) + sets.sorted(by: byName)
    }

    /// Makes an empty group in `folder` called `name`, numbered if the name is taken.
    public static func createGroup(named name: String, in folder: URL) throws -> URL {
        let url = try availableURL(for: name, pathExtension: "", in: folder)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// Writes `contents` as a new set in `folder` called `name`, numbered if the name is taken.
    public static func createSet(named name: String, contents: Data, in folder: URL) throws -> URL {
        let url = try newSetURL(named: name, in: folder)
        try contents.write(to: url, options: .withoutOverwriting)
        return url
    }

    /// Where a set called `name` can be saved in `folder`, numbered if the name is taken.
    public static func newSetURL(named name: String, in folder: URL) throws -> URL {
        try availableURL(for: name, pathExtension: fileExtension, in: folder)
    }

    /// Moves a set or group into `folder`, numbering its name if another item there has it.
    /// Returns where it is now; an item already in `folder` stays as it is.
    public static func move(_ item: URL, into folder: URL) throws -> URL {
        let item = item.standardizedFileURL
        let folder = folder.standardizedFileURL
        guard item.deletingLastPathComponent().path != folder.path else { return item }
        guard !folder.pathComponents.starts(with: item.pathComponents) else { throw Failure.groupIntoItself }
        let isSet = item.pathExtension.lowercased() == fileExtension
        let name = isSet ? item.deletingPathExtension().lastPathComponent : item.lastPathComponent
        let destination = try availableURL(for: name, pathExtension: isSet ? item.pathExtension : "", in: folder)
        try FileManager.default.moveItem(at: item, to: destination)
        return destination
    }

    /// Dissolves a group: what is in it moves up next to it, numbered if its name is taken there,
    /// and the emptied folder goes to the Trash. No set is deleted.
    public static func ungroup(_ group: URL) throws {
        let parent = group.deletingLastPathComponent()
        for item in try FileManager.default.contentsOfDirectory(at: group, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            _ = try move(item, into: parent)
        }
        try FileManager.default.trashItem(at: group, resultingItemURL: nil)
    }

    /// Renames a set or group in place; a set keeps its extension. Fails if the name is taken.
    public static func rename(_ item: URL, to name: String) throws -> URL {
        let name = try validated(name)
        let isSet = item.pathExtension.lowercased() == fileExtension
        var destination = item.deletingLastPathComponent().appending(component: name, directoryHint: isSet ? .notDirectory : .isDirectory)
        if isSet { destination.appendPathExtension(item.pathExtension) }
        guard destination.lastPathComponent != item.lastPathComponent else { return item }
        try FileManager.default.moveItem(at: item, to: destination)
        return destination
    }

    /// `name` in `folder`, or `name 2`, `name 3`… when it is taken.
    private static func availableURL(for name: String, pathExtension: String, in folder: URL) throws -> URL {
        let name = try validated(name)
        for number in 1... {
            var url = folder.appending(component: number == 1 ? name : "\(name) \(number)")
            if !pathExtension.isEmpty { url.appendPathExtension(pathExtension) }
            if !FileManager.default.fileExists(atPath: url.path) { return url }
        }
        preconditionFailure("unreachable")
    }

    private static func validated(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("."), !trimmed.contains("/"), !trimmed.contains(":") else { throw Failure.invalidName(name) }
        return trimmed
    }
}
