import Foundation

public enum TagReaderError: Error {
    case unreadable(URL)
}

/// Reads raw text tags from MP3 (ID3v2), AIFF/WAV (embedded ID3 chunk) and FLAC (Vorbis comments).
/// Field names are canonical and uppercased; see `ID3Parser`.
public enum TagReader {
    public static func readFields(url: URL) throws -> [String: String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw TagReaderError.unreadable(url) }
        defer { try? handle.close() }
        let file = FileReader(handle: handle)

        let magic = try file.read(at: 0, count: 12)
        guard magic.count >= 4 else { return [:] }
        let tag4 = String(decoding: magic[0..<4], as: UTF8.self)

        if let size = ID3Parser.tagSize(header: try file.read(at: 0, count: ID3Parser.headerSize)) {
            var fields = ID3Parser.parse(try file.read(at: 0, count: size))
            if try file.read(at: UInt64(size), count: 4) == Array("fLaC".utf8) {
                fields.merge(try readFLAC(file, start: UInt64(size) + 4)) { first, _ in first }
            }
            return fields
        }
        switch tag4 {
        case "fLaC":
            return try readFLAC(file, start: 4)
        case "FORM":
            return try readChunks(file, start: 12, bigEndian: true)
        case "RIFF":
            return try readChunks(file, start: 12, bigEndian: false)
        default:
            return [:]
        }
    }

    private static func readChunks(_ file: FileReader, start: UInt64, bigEndian: Bool) throws -> [String: String] {
        var offset = start
        while true {
            let header = try file.read(at: offset, count: 8)
            guard header.count == 8 else { return [:] }
            let id = String(decoding: header[0..<4], as: UTF8.self)
            let size = bigEndian
                ? UInt64(ID3Parser.bigEndian32(header, at: 4))
                : UInt64(header[4]) | UInt64(header[5]) << 8 | UInt64(header[6]) << 16 | UInt64(header[7]) << 24
            if id == "ID3 " || id == "id3 " {
                return ID3Parser.parse(try file.read(at: offset + 8, count: Int(size)))
            }
            offset += 8 + size + (size & 1)
        }
    }

    private static func readFLAC(_ file: FileReader, start: UInt64) throws -> [String: String] {
        var offset = start
        while true {
            let header = try file.read(at: offset, count: 4)
            guard header.count == 4 else { return [:] }
            let isLast = header[0] & 0x80 != 0
            let type = header[0] & 0x7F
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            if type == 4 {
                return parseVorbisComments(try file.read(at: offset + 4, count: length))
            }
            if isLast { return [:] }
            offset += 4 + UInt64(length)
        }
    }

    static func parseVorbisComments(_ b: [UInt8]) -> [String: String] {
        func le32(_ i: Int) -> Int? {
            guard i + 4 <= b.count else { return nil }
            return Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24
        }
        guard let vendorLength = le32(0), let count = le32(4 + vendorLength) else { return [:] }
        var pos = 8 + vendorLength
        var fields: [String: String] = [:]
        for _ in 0..<count {
            guard let length = le32(pos), pos + 4 + length <= b.count else { break }
            let entry = String(decoding: b[(pos + 4)..<(pos + 4 + length)], as: UTF8.self)
            pos += 4 + length
            guard let eq = entry.firstIndex(of: "=") else { continue }
            let name = entry[..<eq].uppercased()
            if fields[name] == nil {
                fields[name] = String(entry[entry.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return fields
    }
}

private struct FileReader {
    let handle: FileHandle

    func read(at offset: UInt64, count: Int) throws -> [UInt8] {
        try handle.seek(toOffset: offset)
        return [UInt8](try handle.read(upToCount: count) ?? Data())
    }
}
