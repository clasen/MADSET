import Foundation

/// The saved form of a set (`.madset`, JSON). Only the arrangement is stored; analysis comes from
/// the cache when the set is opened.
public struct SetFile: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public enum Failure: Error, Equatable {
        case unsupportedVersion(Int)
    }

    public var version: Int
    /// Tempo of the set; nil follows the tracks (median tempo).
    public var bpm: Double?
    public var entries: [SetEntry]

    public init(bpm: Double?, entries: [SetEntry]) {
        version = Self.currentVersion
        self.bpm = bpm
        self.entries = entries
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> SetFile {
        let file = try JSONDecoder().decode(SetFile.self, from: data)
        guard file.version == currentVersion else { throw Failure.unsupportedVersion(file.version) }
        return file
    }
}
