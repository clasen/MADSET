import Foundation
import Testing
@testable import MADSETCore

@Suite struct DuplicateSongsTests {
    private func song(_ path: String, title: String? = nil, artist: String? = nil) -> DuplicateSongs.Song {
        DuplicateSongs.Song(file: URL(filePath: path), tags: TrackTags(title: title, artist: artist))
    }

    @Test func findsTheSameFile() {
        let existing = [song("/music/a.mp3", title: "Alma", artist: "Rhye")]
        let candidates = [song("/music/./a.mp3", title: "Alma", artist: "Rhye"), song("/music/b.mp3", title: "Open", artist: "Rhye")]
        #expect(DuplicateSongs.indices(of: candidates, among: existing) == [0])
    }

    @Test func findsTheSameSongInAnotherFile() {
        let existing = [song("/music/a.mp3", title: "Café  Noir", artist: "Dj X")]
        let candidates = [song("/backup/copy.aiff", title: "cafe noir", artist: "DJ X"), song("/music/c.mp3", title: "Café Noir", artist: "Other")]
        #expect(DuplicateSongs.indices(of: candidates, among: existing) == [0])
    }

    @Test func findsRepeatsWithinTheImport() {
        let candidates = [song("/a/Track One.mp3"), song("/b/track one.flac"), song("/c/Track Two.mp3")]
        #expect(DuplicateSongs.indices(of: candidates, among: []) == [1])
    }

    @Test func comparesUntaggedFilesByName() {
        let existing = [song("/a/Intro.mp3"), song("/a/x.mp3", title: "Intro", artist: "Someone")]
        #expect(DuplicateSongs.indices(of: [song("/b/Intro.wav"), song("/b/y.mp3", title: "Intro")], among: existing) == [0])
    }
}
