import AppKit
import MADSETCore
import SwiftUI

/// Edits the transition into the selected track, and where the track starts and ends, while a single track is selected.
/// Automatic values follow the phases.
struct TransitionInspector: View {
    let document: SetDocument
    let layout: SetLayout

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            if document.selection.count == 1, let id = document.selection.first,
               let index = layout.entries.firstIndex(where: { $0.id == id }),
               let track = document.tracks.first(where: { $0.id == id }) {
                editor(index: index, title: track.title)
            } else if document.selection.count > 1 {
                Text("\(document.selection.count) tracks selected").foregroundStyle(.secondary)
                Spacer()
            } else {
                Text("Select a track to edit its transition").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 64)
        .background(Theme.panel)
    }

    @ViewBuilder private func editor(index: Int, title: String) -> some View {
        let placed = layout.entries[index]
        let phrase = AppConfig.current.analysis.phraseBars
        VStack(alignment: .leading, spacing: 3) {
            Text(index > 0 ? "Transition into" : "Opening track")
                .textCase(.uppercase).font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
        }
        .frame(width: 180, alignment: .leading)

        if index > 0 {
            let previous = layout.entries[index - 1]
            let mixIn = placed.mixInBar(after: previous)
            HStack(spacing: 8) {
                BarStepper(title: "Mix in", icon: "arrow.merge", unit: .position,
                           value: mixIn, step: phrase, range: placed.mixInRange(after: previous)) { bar in
                    document.apply(.mixIn(of: placed, after: previous, atBar: bar))
                }
                .help(String(localized: "Bar of the previous track where this one comes in. The transition keeps its length."))
                BarStepper(title: "Length", icon: "arrow.left.and.right", unit: .length,
                           value: placed.overlapBars, step: phrase, range: placed.transitionLengths(after: previous)) { value in
                    document.apply(.resizeTransition(of: placed, after: previous, to: value))
                }
                .help(String(localized: "Bars both tracks play together. It grows or shrinks on both sides; neither track moves."))
            }
            HStack(spacing: 8) {
                BarStepper(title: "Bass swap", icon: "arrow.up.arrow.down", tint: Color(nsColor: Theme.swap), unit: .position,
                           value: placed.bassSwapBar, step: 1, wheelStep: 2, range: 0...placed.overlapBars) { value in
                    document.edit(placed.id, String(localized: "Move Bass Swap")) { $0.bassSwapBar = value }
                }
                BarStepper(title: "Fade in", icon: "chart.line.uptrend.xyaxis", unit: .length,
                           value: placed.fadeInBars, step: 1, wheelStep: 2, range: 0...placed.overlapBars) { value in
                    document.edit(placed.id, String(localized: "Change Fade In")) { $0.fadeInBars = value }
                }
                .help(String(localized: "Bars this track takes to reach full volume, from the start of the transition."))
                BarStepper(title: "Fade out", icon: "chart.line.downtrend.xyaxis", unit: .length,
                           value: placed.fadeOutBars, step: 1, wheelStep: 2, range: 0...placed.overlapBars) { value in
                    document.edit(placed.id, String(localized: "Change Fade Out")) { $0.fadeOutBars = value }
                }
                .help(String(localized: "Bars the previous track takes to fade out, ending with the transition."))
            }
        }
        Rectangle().fill(Theme.hairline).frame(width: 1, height: 38)
        HStack(spacing: 8) {
            BarStepper(title: "Cue in", icon: "flag", unit: .position,
                       value: placed.cueInBar, step: phrase, range: 0...max(0, placed.cueOutBar - 1)) { value in
                document.edit(placed.id, String(localized: "Change Cue In")) { $0.cueInBar = value }
            }
            BarStepper(title: "Cue out", icon: "flag.checkered", unit: .position,
                       value: placed.cueOutBar, step: phrase,
                       range: (placed.cueInBar + 1)...max(placed.cueInBar + 1, placed.barCount)) { value in
                document.edit(placed.id, String(localized: "Change Cue Out")) { $0.cueOutBar = value }
            }
        }
        Spacer()
        MonitorButton(document: document, entry: placed.id)
        Button {
            var changes: [(Track.ID, (inout SetEntry) -> Void)] = [(placed.id, { entry in
                entry.cueInBar = nil
                entry.cueOutBar = nil
                entry.overlapBars = nil
                entry.bassSwapBar = nil
                entry.fadeInBars = nil
                entry.fadeOutBars = nil
            })]
            if index > 0 { changes.append((layout.entries[index - 1].id, { $0.cueOutBar = nil })) }
            document.apply(ArrangementEdit(name: String(localized: "Reset Transition"), changes: changes))
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "wand.and.stars").font(.system(size: 11, weight: .semibold))
                Text("Auto").textCase(.uppercase).font(.system(size: 11, weight: .bold)).tracking(0.6)
            }
            .padding(.horizontal, 12)
            .frame(height: 26)
        }
        .buttonStyle(FieldButtonStyle())
        .help(String(localized: "Back to the automatic, phrase-aligned transition"))
    }
}

/// Plays the transition into the track on the monitor, again from its lead-in on every press,
/// turning monitor mode on.
private struct MonitorButton: View {
    let document: SetDocument
    let entry: Track.ID

    var body: some View {
        let available = DeviceSettings.shared.hasMonitorOutput
        let tint = Color(nsColor: Theme.monitor)
        Button { document.previewTransition(into: entry) } label: {
            HStack(spacing: 5) {
                Image(systemName: "headphones").font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                Text("Preview").textCase(.uppercase).font(.system(size: 11, weight: .bold)).tracking(0.6)
            }
            .padding(.horizontal, 12)
            .frame(height: 26)
        }
        .buttonStyle(FieldButtonStyle())
        .disabled(!available)
        .help(available
            ? String(localized: "Play this transition on the monitor output, from a few bars before it, in time with the set (turns monitor mode on)")
            : String(localized: "Choose a monitor output in Settings to preview transitions"))
    }
}

/// A bar value with arrows that step it by `step`, clamped to `range`. The scroll wheel over it
/// steps it too, by `wheelStep` if set: up or away increases.
private struct BarStepper: View {
    /// A bar of the track (shown as "bar 12") or a number of bars ("12 bars").
    enum Unit { case position, length }

    let title: LocalizedStringKey
    let icon: String
    var tint: Color = .secondary
    let unit: Unit
    let value: Int
    let step: Int
    /// Coarser step for the scroll wheel, landing on its multiples; the arrows still reach the values between.
    var wheelStep: Int?
    let range: ClosedRange<Int>
    let set: (Int) -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .bold)).foregroundStyle(tint).frame(width: 12)
                Text(title).textCase(.uppercase).font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
            }
            .frame(height: 11)
            .padding(.leading, 2)
            HStack(spacing: 0) {
                arrow("chevron.left", enabled: value > range.lowerBound) { move(by: -1) }
                separator
                valueText.frame(minWidth: 62)
                separator
                arrow("chevron.right", enabled: value < range.upperBound) { move(by: 1) }
            }
            .frame(height: 26)
            .background(hovering ? Theme.controlHover : Theme.control, in: Self.shape)
            .overlay(Self.shape.strokeBorder(hovering ? tint.opacity(0.7) : Theme.hairline))
            .clipShape(Self.shape)
        }
        .fixedSize()
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .background(ScrollWheelSteps { steps, _ in wheel(by: steps) })
    }

    private static let shape = RoundedRectangle(cornerRadius: 6)

    private var valueText: some View {
        let number = Text(value, format: .number.grouping(.never)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
        let unitFont = Font.system(size: 10, weight: .medium)
        return HStack(alignment: .firstTextBaseline, spacing: 3) {
            switch unit {
            case .position:
                Text("bar").font(unitFont).foregroundStyle(.secondary)
                number
            case .length:
                number
                Text("bars").font(unitFont).foregroundStyle(.secondary)
            }
        }
    }

    private var separator: some View {
        Rectangle().fill(Color.black.opacity(0.35)).frame(width: 1)
    }

    private func move(by steps: Int) {
        moveTo(value + steps * step)
    }

    private func wheel(by steps: Int) {
        guard let wheelStep else { return move(by: steps) }
        // From a value between multiples, the first step lands on the next multiple in that direction.
        let multiple = steps > 0 ? value / wheelStep : (value + wheelStep - 1) / wheelStep
        moveTo((multiple + steps) * wheelStep)
    }

    private func moveTo(_ bar: Int) {
        let target = bar.clamped(to: range)
        if target != value { set(target) }
    }

    private func arrow(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .heavy))
                .frame(width: 22, height: 26)
        }
        .buttonStyle(FieldButtonStyle(filled: false))
        .disabled(!enabled)
    }
}

/// A raised button that lights up while pressed; `filled: false` for buttons inside a field.
private struct FieldButtonStyle: ButtonStyle {
    var filled = true

    func makeBody(configuration: Configuration) -> some View {
        FieldButton(configuration: configuration, filled: filled)
    }

    private struct FieldButton: View {
        let configuration: Configuration
        let filled: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: filled ? 6 : 0)
            configuration.label
                .foregroundStyle(isEnabled ? (hovering || configuration.isPressed ? .primary : .secondary) : .quaternary)
                .background {
                    if configuration.isPressed {
                        shape.fill(Color.white.opacity(0.12))
                    } else if filled {
                        shape.fill(hovering ? Theme.controlHover : Theme.control)
                    }
                }
                .overlay { if filled { shape.strokeBorder(Theme.hairline) } }
                .contentShape(shape)
                .onHover { hovering = $0 }
        }
    }
}

/// Turns the scroll wheel over the view into whole steps: one per wheel notch, one per
/// `pointsPerStep` of trackpad travel. Momentum after the fingers lift is swallowed, not applied.
/// Each call says whether its steps continue the gesture of the call before: on a trackpad, the same
/// touch; on a wheel, notches less than `gestureGap` apart.
/// A local monitor because SwiftUI has no scroll-wheel modifier and an overlay would take the clicks.
struct ScrollWheelSteps: NSViewRepresentable {
    let action: @MainActor (_ steps: Int, _ continuing: Bool) -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) { view.action = action }

    final class MonitorView: NSView {
        var action: @MainActor (Int, Bool) -> Void = { _, _ in }
        private var monitor: Any?
        private var travel: CGFloat = 0
        /// Steps were already sent for the trackpad touch going on, and when the last wheel notch was.
        private var touchStepped = false
        private var lastNotch: TimeInterval?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return handled ? nil : event
            }
        }

        /// Whether the event scrolled over this view, and so was consumed.
        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window,
                  bounds.contains(convert(event.locationInWindow, from: nil)) else { return false }
            guard event.momentumPhase.isEmpty else { return true }
            // Natural scrolling flips the deltas; undo it so moving up always means more.
            let delta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
            guard event.hasPreciseScrollingDeltas else {
                guard delta != 0 else { return true }
                let continuing = lastNotch.map { event.timestamp - $0 < Self.gestureGap } ?? false
                lastNotch = event.timestamp
                action(delta > 0 ? 1 : -1, continuing)
                return true
            }
            if event.phase == .began {
                travel = 0
                touchStepped = false
            }
            travel += delta
            let steps = Int(travel / Self.pointsPerStep)
            if steps != 0 {
                travel -= CGFloat(steps) * Self.pointsPerStep
                action(steps, touchStepped)
                touchStepped = true
            }
            return true
        }

        private static let pointsPerStep: CGFloat = 14
        /// Longest pause between wheel notches of one gesture.
        private static let gestureGap: TimeInterval = 0.4
    }
}
