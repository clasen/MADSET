import Foundation

/// A musical key in Camelot notation (1A...12B), the notation Mixed In Key writes.
public struct CamelotKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public enum Mode: String, Codable, Sendable {
        case minor = "A"
        case major = "B"
    }

    public let number: Int
    public let mode: Mode

    public init(number: Int, mode: Mode) {
        precondition((1...12).contains(number), "Camelot number out of range: \(number)")
        self.number = number
        self.mode = mode
    }

    /// Key whose tonic is `pitchClass` (0 = C ... 11 = B).
    public init(pitchClass: Int, mode: Mode) {
        precondition((0..<12).contains(pitchClass), "Pitch class out of range: \(pitchClass)")
        let offset = mode == .minor ? 5 : 8
        let n = (pitchClass * 7 + offset) % 12
        self.init(number: n == 0 ? 12 : n, mode: mode)
    }

    /// Parses Camelot ("8A", "08a") or musical notation ("Am", "F#m", "Eb", "Bb minor").
    public init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let key = Self.parseCamelot(trimmed) ?? Self.parseMusical(trimmed) {
            self = key
        } else {
            return nil
        }
    }

    public var description: String { "\(number)\(mode.rawValue)" }

    private static func parseCamelot(_ text: String) -> CamelotKey? {
        guard let last = text.last, let mode = Mode(rawValue: last.uppercased()) else { return nil }
        let digits = text.dropLast().trimmingCharacters(in: .whitespaces)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let n = Int(digits), (1...12).contains(n) else {
            return nil
        }
        return CamelotKey(number: n, mode: mode)
    }

    private static let naturalPitchClasses: [Character: Int] = [
        "C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11,
    ]

    private static func parseMusical(_ text: String) -> CamelotKey? {
        var rest = Substring(text)
        guard let rootChar = rest.first?.uppercased().first,
              let natural = naturalPitchClasses[rootChar] else { return nil }
        rest = rest.dropFirst()
        var pitchClass = natural
        if let accidental = rest.first {
            if accidental == "#" || accidental == "♯" {
                pitchClass += 1
                rest = rest.dropFirst()
            } else if accidental == "b" || accidental == "♭" {
                pitchClass += 11
                rest = rest.dropFirst()
            }
        }
        let quality = rest.trimmingCharacters(in: .whitespaces).lowercased()
        let mode: Mode
        switch quality {
        case "", "maj", "major": mode = .major
        case "m", "min", "minor": mode = .minor
        default: return nil
        }
        return CamelotKey(pitchClass: pitchClass % 12, mode: mode)
    }
}
