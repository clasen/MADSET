import Foundation
import MADSETCore

/// A track placed in the set: its arrangement (`entry`) plus whatever is known about it so far.
struct Track: Identifiable, Sendable {
    enum Status: Sendable, Equatable {
        case reading
        case analyzing
        case ready
        case failed(String)
    }

    var entry: SetEntry
    var tags = TrackTags()
    var headerDuration: TimeInterval?
    var analysis: TrackAnalysis?
    var status: Status = .reading

    init(entry: SetEntry) {
        self.entry = entry
    }

    var id: UUID { entry.id }
    var url: URL { entry.file }
    var title: String { tags.title ?? url.deletingPathExtension().lastPathComponent }
    var artist: String? { tags.artist }
    var key: CamelotKey? { tags.key ?? analysis?.detectedKey }
    /// The key came from audio analysis, not from Mixed In Key tags.
    var keyIsDetected: Bool { tags.key == nil && analysis?.detectedKey != nil }
    var bpm: Double? { analysis?.grid.bpm }
    var duration: TimeInterval? { analysis?.duration ?? headerDuration }
    var isPending: Bool { status == .reading || status == .analyzing }

    /// Analyzed tempo differs from the tagged one by more than rounding, octave errors aside.
    var bpmDisagreesWithTag: Bool {
        guard let bpm, let tagged = tags.bpm else { return false }
        return [bpm, bpm * 2, bpm / 2].allSatisfy { abs($0 - tagged) >= 0.6 }
    }

    var layoutInfo: SetLayout.TrackInfo { .init(analysis: analysis, duration: headerDuration) }
}
