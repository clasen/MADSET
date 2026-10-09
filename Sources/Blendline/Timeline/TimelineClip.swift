import Foundation
import BlendlineCore

/// A track as the timeline draws it: its placement in the set and what to show.
struct TimelineClip: Identifiable {
    let placed: PlacedEntry
    /// The following entry, whose transition shapes this clip's end.
    let next: PlacedEntry?
    let barDuration: TimeInterval
    let isFirst: Bool
    let lane: Int
    let title: String
    let artist: String?
    let key: CamelotKey?
    let keyIsDetected: Bool
    let bpm: Double?
    let setBPM: Double
    let energy: Int?
    let energyIsDetected: Bool
    let analysis: TrackAnalysis?
    let isPending: Bool
    let failure: String?

    var id: Track.ID { placed.id }
    var start: TimeInterval { Double(placed.startBar) * barDuration }
    var duration: TimeInterval { Double(placed.lengthBars) * barDuration }
    var end: TimeInterval { start + duration }
    var center: TimeInterval { start + duration / 2 }

    /// Set time of one of the track's own bars.
    func time(ofTrackBar bar: Double) -> TimeInterval { start + (bar - Double(placed.cueInBar)) * barDuration }

    /// Tempo change applied to the track, in percent.
    var stretchPercent: Double? { bpm.map { (setBPM / $0 - 1) * 100 } }

    /// "E6", or "E6*" when the energy was estimated from audio.
    var energyLabel: String? { energy.map { "E\($0)" + (energyIsDetected ? "*" : "") } }

    static func clips(for layout: SetLayout, tracks: [Track]) -> [TimelineClip] {
        precondition(layout.entries.count == tracks.count, "Layout and tracks out of sync")
        return zip(layout.entries, tracks).enumerated().map { index, pair in
            let (placed, track) = pair
            var failure: String?
            if case .failed(let message) = track.status { failure = message }
            return TimelineClip(
                placed: placed,
                next: index + 1 < layout.entries.count ? layout.entries[index + 1] : nil,
                barDuration: layout.barDuration,
                isFirst: index == 0,
                lane: index % 2,
                title: track.title,
                artist: track.artist,
                key: track.key,
                keyIsDetected: track.keyIsDetected,
                bpm: track.bpm,
                setBPM: layout.bpm,
                energy: track.energy,
                energyIsDetected: track.energyIsDetected,
                analysis: track.analysis,
                isPending: track.isPending,
                failure: failure
            )
        }
    }
}
