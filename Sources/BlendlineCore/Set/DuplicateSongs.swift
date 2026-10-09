import Foundation

/// Finds songs that are already in a set: the same file, or another file with the same artist and title
/// (the file name when there is no title tag), compared ignoring case, accents and spacing.
public enum DuplicateSongs {
    public struct Song: Sendable {
        public let file: URL
        public let tags: TrackTags

        public init(file: URL, tags: TrackTags) {
            self.file = file
            self.tags = tags
        }
    }

    /// Indices of the `candidates` that repeat a song of `existing` or an earlier candidate.
    public static func indices(of candidates: [Song], among existing: [Song]) -> [Int] {
        var known = Set(existing.flatMap(keys))
        return candidates.indices.filter { index in
            let keys = keys(of: candidates[index])
            defer { known.formUnion(keys) }
            return !known.isDisjoint(with: keys)
        }
    }

    private static func keys(of song: Song) -> [String] {
        let name = if let title = song.tags.title.map(normalized), !title.isEmpty {
            "tags:" + (song.tags.artist.map(normalized) ?? "") + "\u{1F}" + title
        } else {
            "name:" + normalized(song.file.deletingPathExtension().lastPathComponent)
        }
        return ["file:" + song.file.standardizedFileURL.path, name]
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
