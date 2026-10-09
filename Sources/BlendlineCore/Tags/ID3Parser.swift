import Foundation

/// Minimal ID3v2.3/2.4 reader for the text frames a DJ library needs.
/// Returns canonical field names: TITLE, ARTIST, GENRE, INITIALKEY, BPM, COMMENT and TXXX descriptions uppercased.
enum ID3Parser {
    static let headerSize = 10

    /// Total tag size (header + body) when `header` starts with an ID3v2 header.
    static func tagSize(header: [UInt8]) -> Int? {
        guard header.count >= headerSize, header[0] == 0x49, header[1] == 0x44, header[2] == 0x33 else { return nil }
        return headerSize + syncSafe(header, at: 6)
    }

    static func parse(_ bytes: [UInt8]) -> [String: String] {
        guard let size = tagSize(header: bytes) else { return [:] }
        let major = bytes[3]
        let flags = bytes[5]
        guard major == 3 || major == 4 else { return [:] }

        var body = Array(bytes[headerSize..<min(size, bytes.count)])
        if flags & 0x80 != 0, major == 3 {
            body = removeUnsynchronisation(body)
        }
        var pos = 0
        if flags & 0x40 != 0, body.count >= 4 {
            pos = major == 4 ? syncSafe(body, at: 0) : 4 + bigEndian32(body, at: 0)
        }

        var fields: [String: String] = [:]
        while pos + headerSize <= body.count {
            guard body[pos] != 0 else { break }
            let id = String(decoding: body[pos..<pos + 4], as: UTF8.self)
            let frameSize = major == 4 ? syncSafe(body, at: pos + 4) : bigEndian32(body, at: pos + 4)
            let formatFlags = body[pos + 9]
            let start = pos + headerSize
            let end = start + frameSize
            guard frameSize > 0, end <= body.count else { break }
            pos = end

            let compressedOrEncrypted = major == 4 ? (formatFlags & 0x0C != 0) : (formatFlags & 0xC0 != 0)
            guard !compressedOrEncrypted, isWanted(id) else { continue }
            var payload = Array(body[start..<end])
            if major == 4 {
                if formatFlags & 0x01 != 0 { payload = Array(payload.dropFirst(4)) }
                if formatFlags & 0x02 != 0 { payload = removeUnsynchronisation(payload) }
            }
            guard let (name, value) = decodeFrame(id: id, payload: payload), fields[name] == nil else { continue }
            fields[name] = value
        }
        return fields
    }

    private static let textFrames: [String: String] = [
        "TIT2": "TITLE", "TPE1": "ARTIST", "TCON": "GENRE", "TKEY": "INITIALKEY", "TBPM": "BPM",
    ]

    private static func isWanted(_ id: String) -> Bool {
        textFrames[id] != nil || id == "TXXX" || id == "COMM"
    }

    private static func decodeFrame(id: String, payload: [UInt8]) -> (String, String)? {
        guard let encoding = payload.first else { return nil }
        let content = Array(payload.dropFirst())
        if let name = textFrames[id] {
            guard let value = splitTerminated(content, encoding: encoding).first else { return nil }
            return (name, value)
        }
        if id == "TXXX" {
            let parts = splitTerminated(content, encoding: encoding, limit: 2)
            guard parts.count == 2, !parts[0].isEmpty else { return nil }
            return (parts[0].uppercased(), parts[1])
        }
        if id == "COMM" {
            guard content.count >= 3 else { return nil }
            let parts = splitTerminated(Array(content.dropFirst(3)), encoding: encoding, limit: 2)
            guard parts.count == 2, parts[0].isEmpty else { return nil }
            return ("COMMENT", parts[1])
        }
        return nil
    }

    /// Splits on the encoding's terminator. With `limit`, the last part keeps the remainder.
    private static func splitTerminated(_ bytes: [UInt8], encoding: UInt8, limit: Int = .max) -> [String] {
        let wide = encoding == 1 || encoding == 2
        let step = wide ? 2 : 1
        var parts: [String] = []
        var start = 0
        var i = 0
        while i + step <= bytes.count, parts.count < limit - 1 {
            let isTerminator = wide ? (bytes[i] == 0 && bytes[i + 1] == 0) : bytes[i] == 0
            if isTerminator {
                parts.append(decodeText(Array(bytes[start..<i]), encoding: encoding))
                start = i + step
            }
            i += step
        }
        var tail = Array(bytes[min(start, bytes.count)...])
        while let last = tail.last, last == 0 { tail.removeLast() }
        if wide, tail.count % 2 == 1 { tail.append(0) }
        parts.append(decodeText(tail, encoding: encoding))
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func decodeText(_ bytes: [UInt8], encoding: UInt8) -> String {
        switch encoding {
        case 0: return String(bytes: bytes, encoding: .isoLatin1) ?? ""
        case 1: return String(bytes: bytes, encoding: .utf16) ?? ""
        case 2: return String(bytes: bytes, encoding: .utf16BigEndian) ?? ""
        default: return String(decoding: bytes, as: UTF8.self)
        }
    }

    private static func removeUnsynchronisation(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            out.append(bytes[i])
            if bytes[i] == 0xFF, i + 1 < bytes.count, bytes[i + 1] == 0x00 { i += 1 }
            i += 1
        }
        return out
    }

    static func syncSafe(_ b: [UInt8], at i: Int) -> Int {
        Int(b[i] & 0x7F) << 21 | Int(b[i + 1] & 0x7F) << 14 | Int(b[i + 2] & 0x7F) << 7 | Int(b[i + 3] & 0x7F)
    }

    static func bigEndian32(_ b: [UInt8], at i: Int) -> Int {
        Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
    }
}
