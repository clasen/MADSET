import SwiftUI

struct TimelineView: NSViewRepresentable {
    let clips: [TimelineClip]
    let selection: Track.ID?
    /// Incremented to ask for a zoom that fits the whole set.
    let fitRequest: Int
    let onSelect: (Track.ID?) -> Void
    let onMove: (Track.ID, _ before: Track.ID?) -> Void

    func makeNSView(context: Context) -> TimelineCanvas {
        TimelineCanvas()
    }

    func updateNSView(_ canvas: TimelineCanvas, context: Context) {
        canvas.onSelect = onSelect
        canvas.onMove = onMove
        canvas.clips = clips
        canvas.selectedID = selection
        if canvas.fitRequest != fitRequest {
            canvas.fitRequest = fitRequest
            canvas.fitAll()
        }
    }
}
