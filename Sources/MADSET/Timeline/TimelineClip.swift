import Foundation
import MADSETCore

/// A track as the timeline draws it: where it sits in the set and what to show.
struct TimelineClip: Identifiable {
    let id: Track.ID
    let start: TimeInterval
    let duration: TimeInterval
    let lane: Int
    let title: String
    let artist: String?
    let key: CamelotKey?
    let keyIsDetected: Bool
    let bpm: Double?
    let energy: Int?
    let analysis: TrackAnalysis?
    let isPending: Bool
    let failure: String?

    var end: TimeInterval { start + duration }
    var center: TimeInterval { start + duration / 2 }

    /// Lays the tracks out back to back, alternating lanes like two decks.
    static func layout(_ tracks: [Track]) -> [TimelineClip] {
        var cursor: TimeInterval = 0
        return tracks.enumerated().compactMap { index, track in
            guard let duration = track.duration else { return nil }
            defer { cursor += duration }
            var failure: String?
            if case .failed(let message) = track.status { failure = message }
            return TimelineClip(
                id: track.id,
                start: cursor,
                duration: duration,
                lane: index % 2,
                title: track.title,
                artist: track.artist,
                key: track.key,
                keyIsDetected: track.keyIsDetected,
                bpm: track.bpm,
                energy: track.tags.energy,
                analysis: track.analysis,
                isPending: track.status == .reading || track.status == .analyzing,
                failure: failure
            )
        }
    }
}
