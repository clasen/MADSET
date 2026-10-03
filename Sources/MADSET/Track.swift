import Foundation
import MADSETCore

/// A track placed in the set, with whatever is known about it so far.
struct Track: Identifiable, Sendable {
    enum Status: Sendable, Equatable {
        case reading
        case analyzing
        case ready
        case failed(String)
    }

    let id = UUID()
    let url: URL
    var tags = TrackTags()
    var headerDuration: TimeInterval?
    var analysis: TrackAnalysis?
    var status: Status = .reading

    var title: String { tags.title ?? url.deletingPathExtension().lastPathComponent }
    var artist: String? { tags.artist }
    var key: CamelotKey? { tags.key ?? analysis?.detectedKey }
    /// The key came from audio analysis, not from Mixed In Key tags.
    var keyIsDetected: Bool { tags.key == nil && analysis?.detectedKey != nil }
    var bpm: Double? { analysis?.grid.bpm }
    var duration: TimeInterval? { analysis?.duration ?? headerDuration }

    /// Analyzed tempo differs from the tagged one by more than rounding, octave errors aside.
    var bpmDisagreesWithTag: Bool {
        guard let bpm, let tagged = tags.bpm else { return false }
        return [bpm, bpm * 2, bpm / 2].allSatisfy { abs($0 - tagged) >= 0.6 }
    }
}
