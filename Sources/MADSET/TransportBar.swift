import MADSETCore
import SwiftUI

/// Playback, set tempo and the selected track's transition, under the timeline.
struct TransportBar: View {
    let document: SetDocument
    let layout: SetLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                Button {
                    document.togglePlayback()
                } label: {
                    Image(systemName: document.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
                }
                .help(document.isPlaying ? String(localized: "Pause (Space)") : String(localized: "Play (Space)"))

                SwiftUI.TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    Text("\(formatDuration(document.currentTime)) / \(formatDuration(layout.duration))")
                        .monospacedDigit()
                        .task(id: document.currentTime) { document.playbackTick() }
                }
                .frame(minWidth: 130, alignment: .leading)

                Divider().frame(height: 18)
                TempoControl(document: document, layout: layout)
                Spacer()
            }
            TransitionInspector(document: document, layout: layout)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct TempoControl: View {
    let document: SetDocument
    let layout: SetLayout

    var body: some View {
        HStack(spacing: 6) {
            Text("Tempo").foregroundStyle(.secondary)
            Text(String(format: "%.1f BPM", layout.bpm)).monospacedDigit()
            Stepper("", value: Binding(get: { layout.bpm }, set: { document.setTempo($0) }), in: 60...200, step: 0.5)
                .labelsHidden()
            if document.tempo == nil {
                Text("auto").font(.caption).foregroundStyle(.secondary)
                    .help(String(localized: "Median tempo of the tracks. Change it to fix the set tempo."))
            } else {
                Button("Auto") { document.setTempo(nil) }
                    .controlSize(.small)
                    .help(String(localized: "Follow the median tempo of the tracks"))
            }
        }
    }
}

/// Edits how the selected track enters (and where it starts and ends). Automatic values follow the phases.
private struct TransitionInspector: View {
    let document: SetDocument
    let layout: SetLayout

    var body: some View {
        if let index = layout.entries.firstIndex(where: { $0.id == document.selection }) {
            let placed = layout.entries[index]
            let phrase = AppConfig.current.analysis.phraseBars
            HStack(spacing: 14) {
                if index > 0 {
                    barStepper("Transition", value: placed.overlapBars, isPosition: false, step: phrase, range: 0...max(0, placed.lengthBars - 1)) { value in
                        document.edit(placed.id, String(localized: "Change Transition")) { $0.overlapBars = value }
                    }
                    barStepper("Bass swap", value: placed.bassSwapBar, isPosition: true, step: 1, range: 0...placed.overlapBars) { value in
                        document.edit(placed.id, String(localized: "Move Bass Swap")) { $0.bassSwapBar = value }
                    }
                }
                barStepper("Cue in", value: placed.cueInBar, isPosition: true, step: phrase, range: 0...max(0, placed.cueOutBar - 1)) { value in
                    document.edit(placed.id, String(localized: "Change Cue In")) { $0.cueInBar = value }
                }
                barStepper("Cue out", value: placed.cueOutBar, isPosition: true, step: phrase, range: (placed.cueInBar + 1)...max(placed.cueInBar + 1, placed.cueOutBar + 512)) { value in
                    document.edit(placed.id, String(localized: "Change Cue Out")) { $0.cueOutBar = value }
                }
                Button("Auto") {
                    document.edit(placed.id, String(localized: "Reset Transition")) { entry in
                        entry.cueInBar = nil
                        entry.cueOutBar = nil
                        entry.overlapBars = nil
                        entry.bassSwapBar = nil
                    }
                }
                .controlSize(.small)
                .help(String(localized: "Back to the automatic, phrase-aligned transition"))
            }
        } else {
            Text("Select a track to edit its transition").foregroundStyle(.secondary).frame(height: 22)
        }
    }

    /// A bar count (`isPosition` false) or a bar position, with a stepper clamped to `range`.
    private func barStepper(_ title: LocalizedStringKey, value: Int, isPosition: Bool, step: Int, range: ClosedRange<Int>, set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            Text(isPosition ? "bar \(value)" : "\(value) bars").monospacedDigit()
            Stepper("", value: Binding(get: { value }, set: { set(min(max($0, range.lowerBound), range.upperBound)) }), step: step)
                .labelsHidden()
        }
        .fixedSize()
    }
}
