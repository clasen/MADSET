import Foundation

/// Turns raw tag fields into `TrackTags`, understanding the conventions Mixed In Key writes:
/// key in TKEY / INITIALKEY, energy in a TXXX "EnergyLevel" field, and comments such as
/// "6", "8A - 6" or "8A - Energy 6".
public enum MIKTags {
    public static func read(url: URL) throws -> TrackTags {
        interpret(try TagReader.readFields(url: url))
    }

    public static func interpret(_ fields: [String: String]) -> TrackTags {
        let comment = fields["COMMENT"].map(parseComment)
        return TrackTags(
            title: nonEmpty(fields["TITLE"]),
            artist: nonEmpty(fields["ARTIST"]),
            genre: nonEmpty(fields["GENRE"]),
            key: fields["INITIALKEY"].flatMap(CamelotKey.init(parsing:)) ?? comment?.key,
            energy: fields["ENERGYLEVEL"].flatMap(parseEnergy) ?? comment?.energy,
            bpm: fields["BPM"].flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) }.flatMap { $0 > 0 ? $0 : nil }
        )
    }

    static func parseComment(_ text: String) -> (key: CamelotKey?, energy: Int?) {
        let parts = text.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
        var key: CamelotKey?
        var energy: Int?
        for part in parts {
            if key == nil, let parsed = CamelotKey(parsing: part) {
                key = parsed
            } else if energy == nil {
                let stripped = part.lowercased().hasPrefix("energy") ? String(part.dropFirst(6)) : part
                energy = parseEnergy(stripped)
            }
        }
        return (key, energy)
    }

    private static func parseEnergy(_ text: String) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)), (1...10).contains(value) else { return nil }
        return value
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}
