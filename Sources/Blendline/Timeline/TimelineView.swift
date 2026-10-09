import BlendlineCore
import SwiftUI

struct TimelineView: NSViewRepresentable {
    let document: SetDocument
    let clips: [TimelineClip]
    /// Incremented to ask for a zoom that fits the whole set.
    let fitRequest: Int
    @Binding var followsPlayhead: Bool

    func makeNSView(context: Context) -> TimelineCanvas {
        TimelineCanvas()
    }

    func updateNSView(_ canvas: TimelineCanvas, context: Context) {
        let document = document
        canvas.onSelect = { document.selection = $0 }
        canvas.onMove = { document.move($0, before: $1) }
        canvas.onEdit = { document.apply($0) }
        canvas.onSplit = { document.split($0, atBar: $1) }
        canvas.onRemove = { document.remove($0) }
        canvas.arrange = { TimelineClip.clips(for: document.layout(applying: $0), tracks: document.tracks) }
        canvas.onSeek = { document.seek(to: $0) }
        canvas.playhead = { (document.currentTime, document.isPlaying) }
        canvas.monitorHead = { document.monitorHead }
        canvas.pendingHeads = { (document.pendingPlayhead, document.pendingMonitorHead) }
        canvas.followsPlayhead = followsPlayhead
        canvas.onFollowsPlayheadChange = { followsPlayhead = $0 }
        canvas.clips = clips
        canvas.selectedIDs = document.selection
        if canvas.fitRequest != fitRequest {
            canvas.fitRequest = fitRequest
            canvas.fitAll()
        }
    }
}
