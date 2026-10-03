import MADSETCore
import SwiftUI

struct TimelineView: NSViewRepresentable {
    let document: SetDocument
    let clips: [TimelineClip]
    /// Incremented to ask for a zoom that fits the whole set.
    let fitRequest: Int

    func makeNSView(context: Context) -> TimelineCanvas {
        TimelineCanvas()
    }

    func updateNSView(_ canvas: TimelineCanvas, context: Context) {
        let document = document
        canvas.onSelect = { document.selection = $0 }
        canvas.onMove = { document.move($0, before: $1) }
        canvas.onSetOverlap = { id, bars in
            document.edit(id, String(localized: "Change Transition")) { $0.overlapBars = bars }
        }
        canvas.onSetBassSwap = { id, bar in
            document.edit(id, String(localized: "Move Bass Swap")) { $0.bassSwapBar = bar }
        }
        canvas.onSeek = { document.seek(to: $0) }
        canvas.playhead = { (document.currentTime, document.isPlaying) }
        canvas.clips = clips
        canvas.selectedID = document.selection
        if canvas.fitRequest != fitRequest {
            canvas.fitRequest = fitRequest
            canvas.fitAll()
        }
    }
}
