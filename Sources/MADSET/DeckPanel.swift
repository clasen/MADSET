import MADSETCore
import SwiftUI

/// Two decks and the mixer between them, following the playhead, or the monitor head in monitor mode.
/// Deck A shows the first timeline lane and deck B the second: the track playing on it, or else the
/// next one it will play.
struct DeckPanel: View {
    let document: SetDocument
    let clips: [TimelineClip]
    let layout: SetLayout

    var body: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 1.0 / 20)) { _ in
            let time = document.transportTime
            let decks = [0, 1].map { DeckState(lane: $0, clips: clips, time: time) }
            HStack(spacing: 1) {
                DeckView(lane: 0, deck: decks[0], time: time, seek: document.seek(to:))
                MixerView(document: document, layout: layout, decks: decks, time: time)
                DeckView(lane: 1, deck: decks[1], time: time, seek: document.seek(to:))
            }
        }
        .background(Theme.hairline)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// What a deck shows at a moment of the set.
private struct DeckState {
    let clip: TimelineClip?
    /// The track is under the playhead, not waiting for its turn.
    let onAir: Bool

    init(lane: Int, clips: [TimelineClip], time: TimeInterval) {
        let mine = clips.filter { $0.lane == lane }
        if let playing = mine.first(where: { $0.start <= time && time < $0.end }) {
            clip = playing
            onAir = true
        } else {
            clip = mine.first { $0.start > time } ?? mine.last
            onAir = false
        }
    }

    func levels(at time: TimeInterval) -> (volume: Float, low: Float) {
        guard onAir, let clip else { return (0, 0) }
        return TransitionCurves.levels(for: clip.placed, next: clip.next, atBar: time / clip.barDuration)
    }
}

private struct DeckView: View {
    let lane: Int
    let deck: DeckState
    let time: TimeInterval
    let seek: (TimeInterval) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let clip = deck.clip {
                header(clip)
                DeckOverview(clip: clip, color: Theme.decks[lane])
                    .equatable()
                    .overlay { progress(clip) }
                    .frame(height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                details(clip)
            } else {
                HStack(spacing: 10) {
                    DeckBadge(lane: lane, onAir: false)
                    Text("No track on this deck").foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.panel)
    }

    private func header(_ clip: TimelineClip) -> some View {
        HStack(alignment: .top, spacing: 10) {
            DeckBadge(lane: lane, onAir: deck.onAir)
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                Text([clip.artist, clip.bpm.map { String(format: "%.1f BPM", $0) }].compactMap { $0 }.joined(separator: "  ·  "))
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(clock(clip)).font(.system(size: 20, weight: .medium)).monospacedDigit()
                    .foregroundStyle(deck.onAir ? .primary : .secondary)
                HStack(spacing: 6) {
                    if let phase = phase(of: clip) {
                        Text(phase.label).font(.system(size: 9, weight: .heavy)).foregroundStyle(Color(nsColor: Theme.color(for: phase)))
                    }
                    KeyChip(key: clip.key, detected: clip.keyIsDetected)
                }
            }
        }
    }

    private func details(_ clip: TimelineClip) -> some View {
        HStack(spacing: 14) {
            if let stretch = clip.stretchPercent {
                Text(String(format: "%+.1f%%", stretch))
                    .foregroundStyle(abs(stretch) > 6 ? Color.orange : Color.secondary)
                    .help(String(localized: "Stretched \(String(format: "%+.1f%%", stretch)) to the set tempo"))
            }
            if let energy = clip.energyLabel { Text(energy) }
            Text("Bar \(currentBar(clip)) / \(clip.placed.lengthBars)")
            Spacer()
            if deck.onAir {
                Text("On air").foregroundStyle(Theme.decks[lane])
            } else if clip.start > time {
                Text("Next")
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .textCase(.uppercase)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }

    /// Shades what has played and marks the playhead; a click seeks there.
    private func progress(_ clip: TimelineClip) -> some View {
        GeometryReader { geometry in
            let fraction = ((time - clip.start) / clip.duration).clamped(to: 0...1)
            let x = geometry.size.width * fraction
            ZStack(alignment: .leading) {
                Color.black.opacity(0.45).frame(width: x)
                Rectangle().fill(.white).frame(width: 2).offset(x: x - 1).opacity(deck.onAir ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { location in
                seek(clip.start + clip.duration * Double(location.x / geometry.size.width))
            }
        }
    }

    /// Remaining time while on air, otherwise the wait until the track starts.
    private func clock(_ clip: TimelineClip) -> String {
        if deck.onAir { return "-" + formatDuration(clip.end - time) }
        if clip.start > time { return String(localized: "in \(formatDuration(clip.start - time))") }
        return "--:--"
    }

    /// Bar of the cued part under the playhead, counted from 1.
    private func currentBar(_ clip: TimelineClip) -> Int {
        deck.onAir ? Int((time - clip.start) / clip.barDuration) + 1 : 1
    }

    private func phase(of clip: TimelineClip) -> Phase? {
        let bar = clip.placed.cueInBar + currentBar(clip) - 1
        return clip.analysis?.sections.first { $0.startBar <= bar && bar < $0.endBar }?.phase
    }
}

private struct DeckBadge: View {
    let lane: Int
    let onAir: Bool

    var body: some View {
        Text(lane == 0 ? "A" : "B")
            .font(.system(size: 14, weight: .heavy))
            .foregroundStyle(onAir ? .black : Theme.decks[lane])
            .frame(width: 28, height: 28)
            .background(onAir ? Theme.decks[lane] : Theme.control, in: RoundedRectangle(cornerRadius: 5))
    }
}

/// The cued part of a track: three-band waveform, phases along the bottom and its transitions shaded.
private struct DeckOverview: View, Equatable {
    let clip: TimelineClip
    let color: Color

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.clip.placed == b.clip.placed && a.clip.next == b.clip.next && a.clip.barDuration == b.clip.barDuration
            && a.clip.analysis?.grid == b.clip.analysis?.grid && a.color == b.color
    }

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.4)))
            let placed = clip.placed
            let length = Double(placed.lengthBars)
            func x(ofBar bar: Double) -> CGFloat { size.width * CGFloat((bar - Double(placed.cueInBar)) / length) }

            let transitions = transitionRegions()
            for region in transitions {
                let rect = CGRect(x: x(ofBar: region.lowerBound), y: 0, width: x(ofBar: region.upperBound) - x(ofBar: region.lowerBound), height: size.height)
                context.fill(Path(rect), with: .color(.white.opacity(0.09)))
            }
            if let analysis = clip.analysis {
                drawWaveform(analysis, in: &context, size: CGSize(width: size.width, height: size.height - 4))
                for section in analysis.sections {
                    let x0 = max(0, x(ofBar: Double(section.startBar)))
                    let x1 = min(size.width, x(ofBar: Double(section.endBar)))
                    guard x1 > x0 else { continue }
                    context.fill(Path(CGRect(x: x0, y: size.height - 3, width: x1 - x0, height: 3)), with: .color(Color(nsColor: Theme.color(for: section.phase))))
                }
            }
            for region in transitions {
                let rect = CGRect(x: x(ofBar: region.lowerBound), y: size.height - 3, width: x(ofBar: region.upperBound) - x(ofBar: region.lowerBound), height: 3)
                context.fill(Path(rect), with: .color(color))
            }
        }
    }

    /// Track bars where this track mixes with the previous and the next one.
    private func transitionRegions() -> [ClosedRange<Double>] {
        let placed = clip.placed
        var regions: [ClosedRange<Double>] = []
        if !clip.isFirst, placed.overlapBars > 0 {
            regions.append(Double(placed.cueInBar)...Double(placed.cueInBar + placed.overlapBars))
        }
        if let next = clip.next, next.overlapBars > 0 {
            regions.append(Double(placed.cueOutBar - next.overlapBars)...Double(placed.cueOutBar))
        }
        return regions
    }

    private func drawWaveform(_ analysis: TrackAnalysis, in context: inout GraphicsContext, size: CGSize) {
        let waveform = analysis.waveform
        let columns = Int(size.width)
        guard columns > 1, waveform.count > 0 else { return }
        let grid = analysis.grid
        let start = grid.barStart(clip.placed.cueInBar)
        let secondsPerColumn = Double(clip.placed.lengthBars) * grid.barDuration / Double(columns)
        let middle = size.height / 2
        let bands: [(Data, NSColor, CGFloat)] = [(waveform.low, Theme.waveLow, 1), (waveform.mid, Theme.waveMid, 0.72), (waveform.high, Theme.waveHigh, 0.45)]
        for (data, color, scale) in bands {
            var tops: [CGPoint] = []
            tops.reserveCapacity(columns)
            data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                for column in 0..<columns {
                    let first = Int((start + Double(column) * secondsPerColumn) * waveform.pointsPerSecond)
                    let last = min(waveform.count, max(first + 1, Int((start + Double(column + 1) * secondsPerColumn) * waveform.pointsPerSecond)))
                    var peak: UInt8 = 0
                    if first >= 0, first < last { for i in first..<last { peak = max(peak, bytes[i]) } }
                    tops.append(CGPoint(x: CGFloat(column), y: middle - CGFloat(peak) / 255 * middle * scale))
                }
            }
            var path = Path()
            path.addLines(tops + tops.reversed().map { CGPoint(x: $0.x, y: 2 * middle - $0.y) })
            path.closeSubpath()
            context.fill(path, with: .color(Color(nsColor: color)))
        }
    }
}

/// Transport, the decks' levels in the transition, and the set tempo.
private struct MixerView: View {
    let document: SetDocument
    let layout: SetLayout
    let decks: [DeckState]
    let time: TimeInterval

    private var playColor: Color { document.monitorMode ? Color(nsColor: Theme.monitor) : Theme.play }

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 18) {
                ChannelMeter(levels: decks[0].levels(at: time), color: Theme.decks[0])
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        Button { document.seek(to: 0) } label: {
                            Image(systemName: "backward.end.fill")
                                .frame(width: 34, height: 30)
                                .background(Theme.control, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .help(String(localized: "Back to Start"))
                        Button { document.togglePlayback() } label: {
                            Image(systemName: document.transportIsPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(playColor)
                                .frame(width: 60, height: 30)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(playColor, lineWidth: 2))
                        }
                        .help(document.transportIsPlaying ? String(localized: "Pause (Space)") : String(localized: "Play (Space)"))
                    }
                    .buttonStyle(.plain)
                    Text(formatDuration(time)).font(.system(size: 22, weight: .medium)).monospacedDigit()
                        .foregroundStyle(document.monitorMode ? Color(nsColor: Theme.monitor) : .primary)
                    if document.monitorMode {
                        Text("Main \(formatDuration(document.currentTime))")
                            .textCase(.uppercase).font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary)
                    } else {
                        Text("/ \(formatDuration(layout.duration))").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                ChannelMeter(levels: decks[1].levels(at: time), color: Theme.decks[1])
            }
            TempoControl(document: document, layout: layout)
        }
        .padding(12)
        .frame(width: 290)
        .overlay(alignment: .topLeading) {
            if document.monitorMode {
                Image(systemName: "headphones")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(Color(nsColor: Theme.monitor))
                    .padding(8)
                    .help(String(localized: "Monitor Mode"))
            }
        }
        .frame(maxHeight: .infinity)
        .background(Theme.panel)
    }
}

/// A deck's volume and lows as the transition curves set them.
private struct ChannelMeter: View {
    let levels: (volume: Float, low: Float)
    let color: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            bar(levels.volume, color)
            bar(levels.low, Color(nsColor: Theme.waveLow))
        }
        .frame(height: 72)
        .help(String(localized: "Volume and lows of the deck"))
    }

    private func bar(_ level: Float, _ color: Color) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(color).frame(height: geometry.size.height * CGFloat(level))
            }
        }
        .frame(width: 6)
    }
}

private struct TempoControl: View {
    let document: SetDocument
    let layout: SetLayout

    var body: some View {
        HStack(spacing: 8) {
            let median = document.medianTempo
            Button { document.applyMedianTempo() } label: {
                Text("Auto")
                    .textCase(.uppercase)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 52, height: 24)
                    .background(Theme.control, in: RoundedRectangle(cornerRadius: 5))
            }
            .disabled(median == nil || median == layout.bpm)
            .help(String(localized: "Set the tempo to the median of the tracks. Later edits don't change it."))
            VStack(spacing: 0) {
                Text(String(format: "%.1f", layout.bpm)).font(.system(size: 17, weight: .semibold)).monospacedDigit()
                Text("Set BPM").textCase(.uppercase).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .frame(width: 64)
            HStack(spacing: 2) {
                step("minus", -Self.tempoStep)
                step("plus", Self.tempoStep)
            }
        }
        .buttonStyle(.plain)
        // Several steps can come before the view updates, so they add to the document's tempo.
        .background(ScrollWheelSteps { steps, continuing in
            document.setTempo(document.effectiveTempo + Double(steps) * Self.tempoStep, continuing: continuing)
        })
    }

    private static let tempoStep = 0.5

    private func step(_ symbol: String, _ delta: Double) -> some View {
        Button { document.setTempo(layout.bpm + delta) } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 26, height: 24)
                .background(Theme.control, in: RoundedRectangle(cornerRadius: 5))
        }
    }
}
