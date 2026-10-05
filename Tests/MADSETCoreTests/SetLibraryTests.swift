import Foundation
import Testing
@testable import MADSETCore

@Suite struct SetLibraryTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "madset-library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func makeSet(_ path: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: url)
    }

    private func makeGroup(_ path: String) throws {
        try FileManager.default.createDirectory(at: root.appending(path: path), withIntermediateDirectories: true)
    }

    private func names(_ items: [SetLibrary.Item]) -> [String] { items.map(\.name) }

    @Test func listsGroupsFirstThenSetsSortedLikeFinder() throws {
        try makeSet("Set 10.madset")
        try makeSet("Set 9.madset")
        try makeSet("notes.txt")
        try makeSet(".hidden.madset")
        try makeSet("Radio/Episode 1.madset")
        try makeSet("Club/Peak.madset")
        try makeGroup("Club/Empty")

        let items = try SetLibrary.items(in: root)
        #expect(names(items) == ["Club", "Radio", "Set 9", "Set 10"])
        #expect(items[0].isGroup && !items[2].isGroup)
        #expect(names(items[0].children ?? []) == ["Empty", "Peak"])
        #expect(items[0].children?[0].children == [])
    }

    @Test func numbersNewItemsWhoseNameIsTaken() throws {
        let first = try SetLibrary.createGroup(named: "Club", in: root)
        let second = try SetLibrary.createGroup(named: "Club", in: root)
        let set = try SetLibrary.createSet(named: "Club", contents: Data("{}".utf8), in: root)
        #expect(first.lastPathComponent == "Club")
        #expect(second.lastPathComponent == "Club 2")
        #expect(set.lastPathComponent == "Club.madset")
        #expect(throws: SetLibrary.Failure.invalidName("a/b")) { try SetLibrary.createGroup(named: "a/b", in: root) }
    }

    @Test func movesIntoAGroupNumberingAClash() throws {
        try makeSet("Peak.madset")
        try makeSet("Club/Peak.madset")
        let moved = try SetLibrary.move(root.appending(path: "Peak.madset"), into: root.appending(path: "Club"))
        #expect(moved.lastPathComponent == "Peak 2.madset")
        #expect(names(try SetLibrary.items(in: root)) == ["Club"])
        #expect(names(try SetLibrary.items(in: root.appending(path: "Club"))) == ["Peak", "Peak 2"])
    }

    @Test func leavesAnItemAlreadyInTheGroupInPlace() throws {
        try makeSet("Club/Peak.madset")
        let url = root.appending(path: "Club/Peak.madset")
        #expect(try SetLibrary.move(url, into: root.appending(path: "Club")).path == url.standardizedFileURL.path)
        #expect(names(try SetLibrary.items(in: root.appending(path: "Club"))) == ["Peak"])
    }

    @Test func refusesToMoveAGroupIntoItself() throws {
        try makeGroup("Club/Warmup")
        let club = root.appending(path: "Club")
        #expect(throws: SetLibrary.Failure.groupIntoItself) { try SetLibrary.move(club, into: club.appending(path: "Warmup")) }
        #expect(throws: SetLibrary.Failure.groupIntoItself) { try SetLibrary.move(club, into: club) }
    }

    @Test func ungroupingKeepsEverySet() throws {
        try makeSet("Peak.madset")
        try makeSet("Club/Peak.madset")
        try makeSet("Club/Warmup/Early.madset")
        try SetLibrary.ungroup(root.appending(path: "Club"))
        let items = try SetLibrary.items(in: root)
        #expect(names(items) == ["Warmup", "Peak", "Peak 2"])
        #expect(names(items[0].children ?? []) == ["Early"])
    }

    @Test func renamingASetKeepsItsExtension() throws {
        try makeSet("Club/Peak.madset")
        let renamed = try SetLibrary.rename(root.appending(path: "Club/Peak.madset"), to: " Peak 3h ")
        #expect(renamed.lastPathComponent == "Peak 3h.madset")
        let group = try SetLibrary.rename(root.appending(path: "Club"), to: "Club Nights")
        #expect(names(try SetLibrary.items(in: root)) == ["Club Nights"])
        #expect(names(try SetLibrary.items(in: group)) == ["Peak 3h"])
    }
}
