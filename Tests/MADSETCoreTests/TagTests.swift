import Foundation
import Testing
@testable import MADSETCore

@Suite struct CamelotKeyTests {
    @Test(arguments: [
        ("8A", "8A"), ("08a", "8A"), ("12B", "12B"), ("Am", "8A"), ("F#m", "11A"), ("Ebm", "2A"),
        ("Eb", "5B"), ("C", "8B"), ("G", "9B"), ("Bbm", "3A"), ("Gm", "6A"), ("Fm", "4A"), ("E", "12B"),
        ("Db minor", "12A"), ("B", "1B"),
    ])
    func parses(text: String, expected: String) {
        #expect(CamelotKey(parsing: text)?.description == expected)
    }

    @Test(arguments: ["13A", "0B", "H", "6", "", "Energy 6", "8C"])
    func rejects(text: String) {
        #expect(CamelotKey(parsing: text) == nil)
    }
}

@Suite struct MIKTagsTests {
    @Test func prefersDedicatedFields() {
        let tags = MIKTags.interpret(["INITIALKEY": "9B", "ENERGYLEVEL": "6", "COMMENT": "4A - 3", "BPM": "124", "TITLE": "T", "ARTIST": "A"])
        #expect(tags == TrackTags(title: "T", artist: "A", key: CamelotKey(number: 9, mode: .major), energy: 6, bpm: 124))
    }

    @Test(arguments: [
        ("6", nil, 6), ("5A - 6", "5A", 6), ("8A - Energy 7", "8A", 7), ("8A", "8A", nil), ("Great track", nil, nil),
    ] as [(String, String?, Int?)])
    func readsMixedInKeyComments(comment: String, key: String?, energy: Int?) {
        let tags = MIKTags.interpret(["COMMENT": comment])
        #expect(tags.key?.description == key)
        #expect(tags.energy == energy)
    }
}

@Suite struct TagReaderTests {
    @Test func readsID3v23WithUTF16AndUserFrames() throws {
        let tag = id3(major: 3, frames: [
            textFrame("TIT2", utf16: "Café Noir", major: 3),
            textFrame("TKEY", latin1: "7A", major: 3),
            frame("TXXX", [0] + Array("EnergyLevel".utf8) + [0] + Array("7".utf8), major: 3),
            frame("COMM", [0] + Array("eng".utf8) + [0] + Array("7A - 7".utf8), major: 3),
            frame("APIC", [UInt8](repeating: 0xAB, count: 300), major: 3),
        ])
        let url = try write(tag + [0xFF, 0xFB, 0x90, 0x00], ext: "mp3")
        let fields = try TagReader.readFields(url: url)
        #expect(fields["TITLE"] == "Café Noir")
        #expect(fields["INITIALKEY"] == "7A")
        #expect(fields["ENERGYLEVEL"] == "7")
        #expect(fields["COMMENT"] == "7A - 7")
    }

    @Test func readsID3v24WithSyncSafeFrameSizes() throws {
        let longTitle = String(repeating: "x", count: 200)
        let tag = id3(major: 4, frames: [
            frame("TIT2", [3] + Array(longTitle.utf8), major: 4),
            frame("TBPM", [3] + Array("128".utf8), major: 4),
        ])
        let fields = try TagReader.readFields(url: try write(tag, ext: "mp3"))
        #expect(fields["TITLE"] == longTitle)
        #expect(fields["BPM"] == "128")
    }

    @Test func readsFLACVorbisComments() throws {
        var comments: [UInt8] = le32(6) + Array("vendor".utf8) + le32(2)
        for entry in ["INITIALKEY=5A", "EnergyLevel=4"] { comments += le32(entry.utf8.count) + Array(entry.utf8) }
        let streamInfo: [UInt8] = [0x00, 0, 0, 34] + [UInt8](repeating: 0, count: 34)
        let vorbis: [UInt8] = [0x84] + be24(comments.count) + comments
        let url = try write(Array("fLaC".utf8) + streamInfo + vorbis, ext: "flac")
        let tags = try MIKTags.read(url: url)
        #expect(tags.key?.description == "5A")
        #expect(tags.energy == 4)
    }

    @Test func readsID3ChunkAtTheEndOfAIFF() throws {
        let tag = id3(major: 3, frames: [textFrame("TKEY", latin1: "11B", major: 3)])
        let ssnd: [UInt8] = Array("SSND".utf8) + be32(1001) + [UInt8](repeating: 1, count: 1001) + [0]
        let id3Chunk: [UInt8] = Array("ID3 ".utf8) + be32(tag.count) + tag
        let body: [UInt8] = Array("AIFF".utf8) + ssnd + id3Chunk
        let url = try write(Array("FORM".utf8) + be32(body.count) + body, ext: "aiff")
        #expect(try MIKTags.read(url: url).key?.description == "11B")
    }

    @Test func unknownContainersHaveNoTags() throws {
        #expect(try TagReader.readFields(url: try write(Array("OggS....".utf8), ext: "ogg")).isEmpty)
    }

    // MARK: - Byte builders

    private func id3(major: UInt8, frames: [[UInt8]]) -> [UInt8] {
        let body = frames.flatMap { $0 } + [UInt8](repeating: 0, count: 16)
        return Array("ID3".utf8) + [major, 0, 0] + syncSafe(body.count) + body
    }

    private func frame(_ id: String, _ payload: [UInt8], major: UInt8) -> [UInt8] {
        Array(id.utf8) + (major == 4 ? syncSafe(payload.count) : be32(payload.count)) + [0, 0] + payload
    }

    private func textFrame(_ id: String, latin1 text: String, major: UInt8) -> [UInt8] {
        frame(id, [0] + Array(text.data(using: .isoLatin1)!), major: major)
    }

    private func textFrame(_ id: String, utf16 text: String, major: UInt8) -> [UInt8] {
        frame(id, [1] + Array(text.data(using: .utf16)!), major: major)
    }

    private func syncSafe(_ n: Int) -> [UInt8] {
        [UInt8((n >> 21) & 0x7F), UInt8((n >> 14) & 0x7F), UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)]
    }

    private func be32(_ n: Int) -> [UInt8] { [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] }
    private func be24(_ n: Int) -> [UInt8] { [UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] }
    private func le32(_ n: Int) -> [UInt8] { [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 24) & 0xFF)] }

    private func write(_ bytes: [UInt8], ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "madset-\(UUID().uuidString).\(ext)")
        try Data(bytes).write(to: url)
        return url
    }
}
