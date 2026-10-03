import AppKit
import MADSETCore

/// The set on a horizontal time axis at the set tempo, in two lanes like two decks; transitions are
/// where consecutive tracks overlap.
///
/// - Scroll pans; ⌘/⌥-scroll or pinch zooms around the pointer.
/// - Drag a transition (where two clips overlap) to move it while both tracks stay where they are:
///   the outgoing track plays longer or shorter and the incoming one starts further in or earlier.
///   Dragging the first clip moves its transition out.
/// - Drag any other clip to move it under its transition in, which stays where it is: a different
///   part of the track plays in it.
/// - Drag a clip's leading or trailing edge to trim its start or end, which shortens or lengthens
///   its transition without moving either track or the bass swap.
///   Transitions snap to phrases, ⌥ to bars; they may run into silence before or after a track's
///   audio as long as both tracks play in them.
/// - ⌘-drag a clip, or drag the first one when it is alone, to reorder.
/// - Right-click a clip to split it there into two tracks, at the nearest phrase (⌥ bar).
/// - Right-click a clip to remove its track from the set; ⌘⌫ does it for the selection (see `ContentView`).
/// - Drag the BASS marker to move the bass swap; click the ruler to move the playhead.
/// - While playing, the view pages along with the playhead if `followsPlayhead`. Scrolling or zooming
///   the playhead out of view turns that off; turning it on brings the playhead back into view.
final class TimelineCanvas: NSView {
    var clips: [TimelineClip] = [] {
        didSet {
            if case .adjust(_, _, let edit?) = gesture { preview = arrange(edit) } else { preview = nil }
            if !userHasNavigated, oldValue.last?.end != clips.last?.end { fitAll() }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    var selectedID: Track.ID? {
        didSet {
            guard selectedID != oldValue else { return }
            if !isSelectingFromCanvas { revealSelection() }
            needsDisplay = true
        }
    }

    var fitRequest = 0
    var onSelect: (Track.ID?) -> Void = { _ in }
    var onMove: (Track.ID, _ before: Track.ID?) -> Void = { _, _ in }
    var onEdit: (ArrangementEdit) -> Void = { _ in }
    /// Splits a track at one of its own bars.
    var onSplit: (Track.ID, _ bar: Int) -> Void = { _, _ in }
    var onRemove: (Track.ID) -> Void = { _ in }
    /// The clips an edit would leave, to preview a drag before it is committed.
    var arrange: (ArrangementEdit) -> [TimelineClip] = { _ in [] }
    var onSeek: (TimeInterval) -> Void = { _ in }
    var playhead: () -> (time: TimeInterval, isPlaying: Bool) = { (0, false) }
    var followsPlayhead = true {
        didSet { if followsPlayhead, !oldValue { followPlayhead(to: playhead().time) } }
    }
    var onFollowsPlayheadChange: (Bool) -> Void = { _ in }

    /// Every change of the view's position moves the drag handles, so their cursor rects follow it.
    private var origin: TimeInterval = 0 { didSet { window?.invalidateCursorRects(for: self) } }
    private var pointsPerSecond: Double = 1 { didSet { window?.invalidateCursorRects(for: self) } }
    private var userHasNavigated = false
    private var isSelectingFromCanvas = false
    private var gesture: Gesture?
    private var preview: [TimelineClip]?
    private var displayLink: CADisplayLink?
    private var drawnPlayhead: TimeInterval = 0

    /// The clips as drawn: the arrangement, or what the drag in progress would make of it.
    private var shown: [TimelineClip] { preview ?? clips }

    private enum Gesture {
        case reorder(id: Track.ID, startX: CGFloat, offset: CGFloat)
        case adjust(Adjustment, startX: CGFloat, edit: ArrangementEdit?)
    }

    /// A value of the arrangement a drag changes, with the placement it had when the drag began.
    private enum Adjustment {
        /// Which part of a track plays under its transition in; see `PlacedEntry.cueIn(movedBy:after:)`.
        case slide(PlacedEntry, previous: PlacedEntry)
        /// Where a transition is, with both tracks staying put; see `PlacedEntry.movingTransition(by:after:)`.
        case transition(PlacedEntry, previous: PlacedEntry)
        /// Where a track starts; see `PlacedEntry.trimmingStart(by:after:)`.
        case trimStart(PlacedEntry, previous: PlacedEntry)
        /// Where a track ends; see `PlacedEntry.trimmingEnd(by:before:)`.
        case trimEnd(PlacedEntry, next: PlacedEntry?)
        /// Where the lows swap within a transition.
        case bassSwap(PlacedEntry)

        func snapBars(phraseBars: Int, fine: Bool) -> Int {
            switch self {
            case .bassSwap: 1
            case .slide, .transition, .trimStart, .trimEnd: fine ? 1 : phraseBars
            }
        }

        /// The edit after a drag of `bars` to the right, or nil when it changes nothing.
        func edit(movedBars bars: Int) -> ArrangementEdit? {
            switch self {
            case .slide(let entry, let previous):
                let cueIn = entry.cueIn(movedBy: bars, after: previous)
                let overlap = entry.overlapBars
                // The automatic overlap depends on the cues, so the transition keeps its length explicitly.
                return cueIn == entry.cueInBar ? nil
                    : ArrangementEdit(name: String(localized: "Move Track"), changes: [(entry.id, {
                        $0.cueInBar = cueIn
                        $0.overlapBars = overlap
                    })])
            case .transition(let entry, let previous):
                let (cueOut, cueIn) = entry.movingTransition(by: bars, after: previous)
                let overlap = entry.overlapBars
                return cueIn == entry.cueInBar ? nil
                    : ArrangementEdit(name: String(localized: "Move Transition"), changes: [
                        (previous.id, { $0.cueOutBar = cueOut }),
                        (entry.id, {
                            $0.cueInBar = cueIn
                            $0.overlapBars = overlap
                        }),
                    ])
            case .trimStart(let entry, let previous):
                let (cueIn, overlap, swap) = entry.trimmingStart(by: bars, after: previous)
                return cueIn == entry.cueInBar ? nil
                    : ArrangementEdit(name: String(localized: "Change Transition"), changes: [(entry.id, {
                        $0.cueInBar = cueIn
                        $0.overlapBars = overlap
                        $0.bassSwapBar = swap
                    })])
            case .trimEnd(let entry, let next):
                let (cueOut, overlap, swap) = entry.trimmingEnd(by: bars, before: next)
                guard cueOut != entry.cueOutBar else { return nil }
                var changes: [(Track.ID, (inout SetEntry) -> Void)] = [(entry.id, { $0.cueOutBar = cueOut })]
                if let next, let overlap, let swap {
                    changes.append((next.id, {
                        $0.overlapBars = overlap
                        $0.bassSwapBar = swap
                    }))
                }
                return ArrangementEdit(name: next == nil ? String(localized: "Change Cue Out") : String(localized: "Change Transition"), changes: changes)
            case .bassSwap(let entry):
                let swap = (entry.bassSwapBar + bars).clamped(to: 0...entry.overlapBars)
                return swap == entry.bassSwapBar ? nil
                    : ArrangementEdit(name: String(localized: "Move Bass Swap"), changes: [(entry.id, { $0.bassSwapBar = swap })])
            }
        }
    }

    private static let rulerHeight: CGFloat = 24
    private static let headerHeight: CGFloat = 20
    private static let lanePadding: CGFloat = 8
    private static let zoomRange: ClosedRange<Double> = 0.02...400
    private static let dragThreshold: CGFloat = 4
    private static let markerHitWidth: CGFloat = 6
    /// Transitions narrower than this draw only their shading: markers and curves would be clutter.
    private static let detailedTransitionWidth: CGFloat = 40

    private var phraseBars: Int { AppConfig.current.analysis.phraseBars }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var setDuration: TimeInterval { shown.map(\.end).max() ?? 0 }

    // MARK: - Navigation

    func fitAll() {
        guard setDuration > 0, bounds.width > 40 else { return }
        pointsPerSecond = (Double(bounds.width - 40) / setDuration).clamped(to: Self.zoomRange)
        origin = -20 / pointsPerSecond
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if !userHasNavigated { fitAll() }
    }

    private var visibleSpan: TimeInterval { Double(bounds.width) / pointsPerSecond }

    /// Zooms so the clip's transition in (or its start, for the first track) fills most of the view.
    private func zoomToTransition(of clip: TimelineClip) {
        let margin = Double(phraseBars) * clip.barDuration
        let span = Double(max(clip.placed.overlapBars, phraseBars)) * clip.barDuration + 2 * margin
        pointsPerSecond = (Double(bounds.width) / span).clamped(to: Self.zoomRange)
        origin = clip.start - margin
        userHasNavigated = true
        needsDisplay = true
    }

    private func revealSelection() {
        guard let clip = shown.first(where: { $0.id == selectedID }) else { return }
        guard clip.start < time(for: 0) || clip.end > time(for: bounds.width) else { return }
        origin = clip.duration < visibleSpan * 0.9 ? clip.center - visibleSpan / 2 : clip.start - visibleSpan * 0.05
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        let precise = event.hasPreciseScrollingDeltas
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            zoom(by: exp(Double(event.scrollingDeltaY) * (precise ? 0.01 : 0.1)), around: convert(event.locationInWindow, from: nil).x)
            return
        }
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        origin -= Double(delta * (precise ? 1 : 12)) / pointsPerSecond
        clampOrigin()
        userHasNavigated = true
        stopFollowingIfPlayheadLeft()
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + Double(event.magnification), around: convert(event.locationInWindow, from: nil).x)
    }

    private func zoom(by factor: Double, around anchorX: CGFloat) {
        let anchor = time(for: anchorX)
        pointsPerSecond = (pointsPerSecond * factor).clamped(to: Self.zoomRange)
        origin = anchor - Double(anchorX) / pointsPerSecond
        clampOrigin()
        userHasNavigated = true
        stopFollowingIfPlayheadLeft()
        needsDisplay = true
    }

    private func clampOrigin() {
        let margin = visibleSpan * 0.5
        origin = origin.clamped(to: -margin...max(-margin, setDuration - margin))
    }

    // MARK: - Playhead

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(advancePlayhead))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func advancePlayhead() {
        let (time, isPlaying) = playhead()
        guard time != drawnPlayhead else { return }
        if isPlaying, followsPlayhead, gesture == nil, followPlayhead(to: time) {
            needsDisplay = true
        } else {
            setNeedsDisplay(playheadRect(at: drawnPlayhead))
            setNeedsDisplay(playheadRect(at: time))
        }
        drawnPlayhead = time
    }

    /// Pages the view so `time` is near its left edge if it is out of view or close to the right edge;
    /// returns whether it did.
    @discardableResult
    private func followPlayhead(to time: TimeInterval) -> Bool {
        let followX = x(for: time)
        guard followX > bounds.width * 0.85 || followX < 0 else { return false }
        origin = time - visibleSpan * 0.1
        needsDisplay = true
        return true
    }

    /// Moving the view away from the playhead while playing means the user wants to look elsewhere.
    private func stopFollowingIfPlayheadLeft() {
        let (time, isPlaying) = playhead()
        guard isPlaying, followsPlayhead, !(0...bounds.width).contains(x(for: time)) else { return }
        followsPlayhead = false
        onFollowsPlayheadChange(false)
    }

    private func playheadRect(at time: TimeInterval) -> CGRect {
        CGRect(x: x(for: time) - 6, y: 0, width: 12, height: bounds.height)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if point.y < Self.rulerHeight {
            onSeek(max(0, time(for: point.x)))
            return
        }
        let clips = shown
        let edge = clips.indices.last { leadingEdgeRect(for: clips[$0])?.contains(point) == true }
        let trailingEdge = clips.indices.last { trailingEdgeRect(for: clips[$0]).contains(point) }
        guard let index = edge ?? trailingEdge ?? clips.lastIndex(where: { rect(for: $0).contains(point) }) ?? transitionIndex(at: point) else {
            select(nil)
            return
        }
        let clip = clips[index]
        select(clip.id)
        if event.clickCount == 2 {
            zoomToTransition(of: clip)
            return
        }

        if let marker = swapMarker(at: point), let owner = clips.first(where: { $0.id == marker.ownerID }) {
            gesture = .adjust(.bassSwap(owner.placed), startX: point.x, edit: nil)
        } else if edge != nil {
            gesture = .adjust(.trimStart(clip.placed, previous: clips[index - 1].placed), startX: point.x, edit: nil)
        } else if trailingEdge != nil {
            gesture = .adjust(.trimEnd(clip.placed, next: clip.next), startX: point.x, edit: nil)
        } else if event.modifierFlags.contains(.command) {
            gesture = .reorder(id: clip.id, startX: point.x, offset: 0)
        } else if let incoming = transitionIndex(at: point) ?? (clip.isFirst && clips.count > 1 ? 1 : nil) {
            gesture = .adjust(.transition(clips[incoming].placed, previous: clips[incoming - 1].placed), startX: point.x, edit: nil)
        } else if clip.isFirst {
            gesture = .reorder(id: clip.id, startX: point.x, offset: 0)
        } else {
            gesture = .adjust(.slide(clip.placed, previous: clips[index - 1].placed), startX: point.x, edit: nil)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        switch gesture {
        case .reorder(let id, let startX, _):
            gesture = .reorder(id: id, startX: startX, offset: x - startX)
        case .adjust(let adjustment, let startX, _):
            let barWidth = CGFloat((clips.first?.barDuration ?? 1) * pointsPerSecond)
            let snap = adjustment.snapBars(phraseBars: phraseBars, fine: event.modifierFlags.contains(.option))
            let bars = Int((Double((x - startX) / barWidth) / Double(snap)).rounded()) * snap
            let edit = adjustment.edit(movedBars: bars)
            gesture = .adjust(adjustment, startX: startX, edit: edit)
            preview = edit.map(arrange)
        case nil:
            return
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            gesture = nil
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
        switch gesture {
        case .reorder(let id, _, let offset) where abs(offset) > Self.dragThreshold:
            onMove(id, dropTarget(for: id, offset: offset)?.id)
        case .adjust(_, _, let edit?):
            // The preview stays up until the edited clips arrive, so the drop does not flicker.
            onEdit(edit)
        default:
            preview = nil
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard gesture == nil, let clip = shown.last(where: { rect(for: $0).contains(point) }) else { return nil }
        select(clip.id)
        let menu = NSMenu()
        if let grid = clip.analysis?.grid { addSplitItem(to: menu, for: clip, grid: grid, at: point, fine: event.modifierFlags.contains(.option)) }
        let remove = menu.addItem(withTitle: String(localized: "Remove Track"), action: #selector(removeFromMenu(_:)), keyEquivalent: "\u{8}")
        remove.keyEquivalentModifierMask = .command
        remove.target = self
        remove.representedObject = clip.id
        return menu
    }

    private func addSplitItem(to menu: NSMenu, for clip: TimelineClip, grid: BeatGrid, at point: CGPoint, fine: Bool) {
        let barWidth = clip.barDuration * pointsPerSecond
        let pointed = Double(clip.placed.cueInBar) + Double(point.x - rect(for: clip).minX) / barWidth
        let phrase = Double(phraseBars)
        let offset = Double(grid.phraseOffsetBars)
        let snapped = fine
            ? Int(pointed.rounded())
            : Int(offset + ((pointed - offset) / phrase).rounded() * phrase)
        let range = clip.placed.splitRange(before: clip.next)
        let bar = range.map { snapped.clamped(to: $0) } ?? snapped
        let item = menu.addItem(withTitle: String(localized: "Split at Bar \(bar)"), action: range == nil ? nil : #selector(splitFromMenu(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = (clip.id, bar)
    }

    @objc private func splitFromMenu(_ item: NSMenuItem) {
        guard let (id, bar) = item.representedObject as? (Track.ID, Int) else { return }
        onSplit(id, bar)
    }

    @objc private func removeFromMenu(_ item: NSMenuItem) {
        guard let id = item.representedObject as? Track.ID else { return }
        onRemove(id)
    }

    override func resetCursorRects() {
        for clip in shown {
            let body = bodyRect(for: clip)
            guard body.intersects(bounds) else { continue }
            if let edge = leadingEdgeRect(for: clip) { addCursorRect(edge, cursor: .resizeLeftRight) }
            addCursorRect(trailingEdgeRect(for: clip), cursor: .resizeLeftRight)
            for marker in markers(of: clip) {
                addCursorRect(CGRect(x: marker.x - Self.markerHitWidth, y: body.minY, width: 2 * Self.markerHitWidth, height: body.height), cursor: .resizeLeftRight)
            }
        }
    }

    private func select(_ id: Track.ID?) {
        isSelectingFromCanvas = true
        selectedID = id
        isSelectingFromCanvas = false
        onSelect(id)
    }

    /// The clip the dragged one would be inserted before; nil means the end of the set.
    private func dropTarget(for id: Track.ID, offset: CGFloat) -> TimelineClip? {
        guard let clip = shown.first(where: { $0.id == id }) else { return nil }
        let center = clip.center + Double(offset) / pointsPerSecond
        return shown.first { $0.id != id && $0.center > center }
    }

    // MARK: - Geometry

    private func x(for time: TimeInterval) -> CGFloat { CGFloat((time - origin) * pointsPerSecond) }
    private func time(for x: CGFloat) -> TimeInterval { origin + Double(x) / pointsPerSecond }

    private var laneHeight: CGFloat { max(56, (bounds.height - Self.rulerHeight - Self.lanePadding * 3) / 2) }

    private func laneRect(_ lane: Int) -> CGRect {
        CGRect(x: 0, y: Self.rulerHeight + Self.lanePadding + CGFloat(lane) * (laneHeight + Self.lanePadding), width: bounds.width, height: laneHeight)
    }

    /// Where a clip is drawn, including the live preview of a drag.
    private func rect(for clip: TimelineClip) -> CGRect {
        let lane = laneRect(clip.lane)
        var r = CGRect(x: x(for: clip.start), y: lane.minY, width: CGFloat(clip.duration * pointsPerSecond), height: lane.height)
        if case .reorder(let id, _, let offset) = gesture, id == clip.id { r.origin.x += offset }
        return r
    }

    private func bodyRect(for clip: TimelineClip) -> CGRect {
        let r = rect(for: clip)
        return CGRect(x: r.minX, y: r.minY + Self.headerHeight, width: r.width, height: r.height - Self.headerHeight)
    }

    /// x of one of the track's own bars inside the clip as drawn.
    private func x(ofTrackBar bar: Double, in clip: TimelineClip) -> CGFloat {
        rect(for: clip).minX + CGFloat((bar - Double(clip.placed.cueInBar)) * clip.barDuration * pointsPerSecond)
    }

    /// Bass-swap markers drawn on a clip: its own transition in and the next track's, with the track each one edits.
    private func markers(of clip: TimelineClip) -> [(x: CGFloat, ownerID: Track.ID)] {
        var result: [(x: CGFloat, ownerID: Track.ID)] = []
        let r = rect(for: clip)
        let barWidth = clip.barDuration * pointsPerSecond
        let placed = clip.placed
        func detailed(_ overlap: Int) -> Bool { CGFloat(Double(overlap) * barWidth) >= Self.detailedTransitionWidth }
        if !clip.isFirst, placed.overlapBars > 0, detailed(placed.overlapBars) {
            result.append((r.minX + CGFloat(Double(placed.bassSwapBar) * barWidth), placed.id))
        }
        if let next = clip.next, next.overlapBars > 0, detailed(next.overlapBars) {
            result.append((r.minX + CGFloat(Double(next.startBar + next.bassSwapBar - placed.startBar) * barWidth), next.id))
        }
        return result
    }

    /// Where a drag trims the clip's start: its leading edge, below the header.
    private func leadingEdgeRect(for clip: TimelineClip) -> CGRect? {
        guard !clip.isFirst else { return nil }
        let body = bodyRect(for: clip)
        return CGRect(x: body.minX - Self.markerHitWidth, y: body.minY, width: 2 * Self.markerHitWidth, height: body.height)
    }

    /// Where a drag trims the clip's end: its trailing edge, below the header.
    private func trailingEdgeRect(for clip: TimelineClip) -> CGRect {
        let body = bodyRect(for: clip)
        return CGRect(x: body.maxX - Self.markerHitWidth, y: body.minY, width: 2 * Self.markerHitWidth, height: body.height)
    }

    /// Index of the incoming clip of the transition under `point`, on either clip's body or the bridge between the lanes.
    private func transitionIndex(at point: CGPoint) -> Int? {
        let clips = shown
        return clips.indices.dropFirst().last { index in
            let clip = clips[index]
            guard clip.placed.overlapBars > 0 else { return false }
            let minX = x(for: clip.start)
            let width = max(4, CGFloat(Double(clip.placed.overlapBars) * clip.barDuration * pointsPerSecond))
            guard point.x >= minX, point.x <= minX + width else { return false }
            let bridge = CGRect(x: minX, y: laneRect(0).maxY, width: width, height: Self.lanePadding)
            return bodyRect(for: clip).contains(point) || bodyRect(for: clips[index - 1]).contains(point) || bridge.contains(point)
        }
    }

    private func swapMarker(at point: CGPoint) -> (x: CGFloat, ownerID: Track.ID)? {
        for clip in shown.reversed() where bodyRect(for: clip).contains(point) {
            if let marker = markers(of: clip).first(where: { abs($0.x - point.x) <= Self.markerHitWidth }) { return marker }
        }
        return nil
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        Theme.background.setFill()
        dirtyRect.fill()
        for lane in 0..<2 {
            Theme.lane.setFill()
            laneRect(lane).intersection(dirtyRect).fill()
        }
        drawRuler(dirtyRect)
        drawTransitionBridges(dirtyRect)

        var dragged: Track.ID?
        if case .reorder(let id, _, _) = gesture { dragged = id }
        for clip in shown where clip.id != dragged && rect(for: clip).intersects(dirtyRect) {
            drawClip(clip, in: context, dirtyRect: dirtyRect)
        }
        if case .reorder(let id, _, let offset) = gesture, let clip = shown.first(where: { $0.id == id }) {
            let markerX = dropTarget(for: id, offset: offset).map { x(for: $0.start) } ?? x(for: setDuration)
            Theme.selection.setFill()
            CGRect(x: markerX - 1.5, y: Self.rulerHeight, width: 3, height: bounds.height - Self.rulerHeight).fill()
            drawClip(clip, in: context, dirtyRect: dirtyRect, alpha: 0.9)
        }
        drawPlayhead(dirtyRect)
    }

    /// Marks every transition across the gap between the lanes, at least a few points wide so it
    /// stays visible when the whole set is in view.
    private func drawTransitionBridges(_ dirtyRect: CGRect) {
        let gap = CGRect(x: 0, y: laneRect(0).maxY, width: bounds.width, height: Self.lanePadding)
        for clip in shown where !clip.isFirst {
            let placed = clip.placed
            guard placed.overlapBars > 0 else { continue }
            let start = x(for: Double(placed.startBar) * clip.barDuration)
            let width = max(4, CGFloat(Double(placed.overlapBars) * clip.barDuration * pointsPerSecond))
            let bridge = CGRect(x: start, y: gap.minY - 2, width: width, height: gap.height + 4)
            guard bridge.intersects(dirtyRect) else { continue }
            Theme.swap.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: bridge, xRadius: 2, yRadius: 2).fill()
        }
    }

    private func drawRuler(_ dirtyRect: CGRect) {
        Theme.ruler.setFill()
        CGRect(x: dirtyRect.minX, y: 0, width: dirtyRect.width, height: Self.rulerHeight).fill()
        let steps: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        let step = steps.first { $0 * pointsPerSecond >= 80 } ?? 3600
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: Theme.secondaryText,
        ]
        var t = max(0, (time(for: dirtyRect.minX - 60) / step).rounded(.down) * step)
        while t <= time(for: dirtyRect.maxX) {
            let px = x(for: t)
            Theme.secondaryText.withAlphaComponent(0.5).setFill()
            CGRect(x: px, y: 14, width: 1, height: Self.rulerHeight - 14).fill()
            NSAttributedString(string: formatDuration(t), attributes: attributes).draw(at: CGPoint(x: px + 4, y: 5))
            t += step
        }
    }

    private func drawPlayhead(_ dirtyRect: CGRect) {
        let px = x(for: drawnPlayhead)
        guard px >= dirtyRect.minX - 6, px <= dirtyRect.maxX + 6 else { return }
        Theme.playhead.setFill()
        CGRect(x: px - 0.75, y: 0, width: 1.5, height: bounds.height).fill()
        let triangle = NSBezierPath()
        triangle.move(to: CGPoint(x: px - 5, y: 0))
        triangle.line(to: CGPoint(x: px + 5, y: 0))
        triangle.line(to: CGPoint(x: px, y: 7))
        triangle.close()
        triangle.fill()
    }

    private func drawClip(_ clip: TimelineClip, in context: CGContext, dirtyRect: CGRect, alpha: CGFloat = 1) {
        let r = rect(for: clip)
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(alpha)

        let shape = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
        Theme.clip.setFill()
        shape.fill()
        context.saveGState()
        shape.addClip()

        let header = CGRect(x: r.minX, y: r.minY, width: r.width, height: Self.headerHeight)
        let body = bodyRect(for: clip)
        if let analysis = clip.analysis {
            drawSections(analysis, clip: clip, body: body)
            drawGrid(analysis, clip: clip, body: body, dirtyRect: dirtyRect)
            drawWaveform(analysis, clip: clip, body: body, dirtyRect: dirtyRect)
            drawKicks(analysis, clip: clip, body: body)
        } else {
            let message = clip.failure.map { String(localized: "Error: \($0)") } ?? String(localized: "Analyzing…")
            drawCentered(message, in: body, color: clip.failure == nil ? Theme.secondaryText : .systemRed)
        }
        drawTransitions(clip, body: body)
        drawHeader(clip, in: header)
        context.restoreGState()

        let selected = clip.id == selectedID
        (selected ? Theme.selection : Theme.clipBorder).setStroke()
        shape.lineWidth = selected ? 2 : 1
        shape.stroke()
    }

    private func drawSections(_ analysis: TrackAnalysis, clip: TimelineClip, body: CGRect) {
        let labelAttributes: (Phase) -> [NSAttributedString.Key: Any] = {
            [.font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: Theme.color(for: $0)]
        }
        for section in analysis.sections {
            let x0 = max(body.minX, x(ofTrackBar: Double(section.startBar), in: clip))
            let x1 = min(body.maxX, x(ofTrackBar: Double(section.endBar), in: clip))
            guard x1 > x0 else { continue }
            let band = CGRect(x: x0, y: body.minY, width: x1 - x0, height: body.height)
            Theme.color(for: section.phase).withAlphaComponent(0.16).setFill()
            band.fill()
            if band.width >= 64 {
                NSAttributedString(string: section.phase.label, attributes: labelAttributes(section.phase))
                    .draw(at: CGPoint(x: band.minX + 4, y: body.minY + 2))
            }
        }
    }

    private func drawGrid(_ analysis: TrackAnalysis, clip: TimelineClip, body: CGRect, dirtyRect: CGRect) {
        let barWidth = clip.barDuration * pointsPerSecond
        guard barWidth * Double(phraseBars) >= 6 else { return }
        let firstVisible = Double(clip.placed.cueInBar) + Double(max(body.minX, dirtyRect.minX) - body.minX) / barWidth
        let lastVisible = Double(clip.placed.cueInBar) + Double(min(body.maxX, dirtyRect.maxX) - body.minX) / barWidth
        func line(atBar bar: Double, alpha: CGFloat) {
            NSColor(white: 1, alpha: alpha).setFill()
            CGRect(x: x(ofTrackBar: bar, in: clip), y: body.minY, width: 1, height: body.height).fill()
        }
        var bar = max(clip.placed.cueInBar, Int(firstVisible.rounded(.down)))
        while Double(bar) <= lastVisible {
            if (bar - analysis.grid.phraseOffsetBars) % phraseBars == 0 {
                line(atBar: Double(bar), alpha: 0.32)
            } else if barWidth >= 6 {
                line(atBar: Double(bar), alpha: 0.12)
            }
            if barWidth / 4 >= 10 {
                for beat in 1..<4 { line(atBar: Double(bar) + Double(beat) / 4, alpha: 0.05) }
            }
            bar += 1
        }
    }

    /// Draws the stretched track: set offset `dt` into the clip shows source time `firstDownbeat + (cueIn + dt / setBar) * trackBar`.
    private func drawWaveform(_ analysis: TrackAnalysis, clip: TimelineClip, body: CGRect, dirtyRect: CGRect) {
        let waveform = analysis.waveform
        let start = max(body.minX, dirtyRect.minX).rounded(.down)
        // Columns sit on whole points, so the outline must reach the first one at or past the dirty
        // edge; stopping short leaves an unfilled sliver at the edge of every partial redraw.
        let end = min(body.maxX, dirtyRect.maxX).rounded(.up)
        guard end > start, waveform.count > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        let middle = body.midY
        let halfHeight = body.height / 2 - 6
        let grid = analysis.grid
        let sourceSecondsPerPoint = grid.barDuration / clip.barDuration / pointsPerSecond
        let sourceAtBodyStart = grid.firstDownbeat + Double(clip.placed.cueInBar) * grid.barDuration

        let bands: [(Data, NSColor, CGFloat)] = [(waveform.low, Theme.waveLow, 1), (waveform.mid, Theme.waveMid, 0.72), (waveform.high, Theme.waveHigh, 0.45)]
        for (data, color, scale) in bands {
            var tops: [CGPoint] = []
            data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                var x = start
                while x <= end {
                    let sourceStart = sourceAtBodyStart + Double(x - body.minX) * sourceSecondsPerPoint
                    let first = Int(sourceStart * waveform.pointsPerSecond)
                    let last = min(waveform.count, max(first + 1, Int((sourceStart + sourceSecondsPerPoint) * waveform.pointsPerSecond)))
                    // Zoomed out, a column spans many points: their mean keeps the dynamics readable.
                    var level: CGFloat = 0
                    if first < last, first >= 0 {
                        var sum = 0
                        for i in first..<last { sum += Int(bytes[i]) }
                        level = CGFloat(sum) / CGFloat(last - first)
                    }
                    tops.append(CGPoint(x: x, y: middle - level / 255 * halfHeight * scale))
                    x += 1
                }
            }
            guard tops.count > 1 else { continue }
            let path = CGMutablePath()
            path.addLines(between: tops + tops.reversed().map { CGPoint(x: $0.x, y: 2 * middle - $0.y) })
            path.closeSubpath()
            context.addPath(path)
            context.setFillColor(color.cgColor)
            context.fillPath()
        }
    }

    private func drawKicks(_ analysis: TrackAnalysis, clip: TimelineClip, body: CGRect) {
        Theme.kick.setFill()
        let barWidth = CGFloat(clip.barDuration * pointsPerSecond)
        for (bar, presence) in analysis.kickPresence.enumerated() where presence >= 0.5 && bar >= clip.placed.cueInBar && bar < clip.placed.cueOutBar {
            CGRect(x: x(ofTrackBar: Double(bar), in: clip), y: body.maxY - 4, width: max(1, barWidth - (barWidth > 4 ? 1 : 0)), height: 3).fill()
        }
    }

    /// Shades the overlaps and draws the volume (white) and lows (dashed blue) curves and the bass-swap markers.
    private func drawTransitions(_ clip: TimelineClip, body: CGRect) {
        let barWidth = clip.barDuration * pointsPerSecond
        let placed = clip.placed
        let next = clip.next
        var regions: [ClosedRange<Double>] = []
        if !clip.isFirst, placed.overlapBars > 0 { regions.append(0...Double(placed.overlapBars)) }
        if let next, next.overlapBars > 0 { regions.append(Double(next.startBar - placed.startBar)...Double(placed.lengthBars)) }

        for region in regions {
            let x0 = body.minX + CGFloat(region.lowerBound * barWidth)
            let x1 = body.minX + CGFloat(region.upperBound * barWidth)
            NSColor(white: 1, alpha: 0.06).setFill()
            CGRect(x: x0, y: body.minY, width: x1 - x0, height: body.height).fill()
            guard x1 - x0 >= Self.detailedTransitionWidth else { continue }

            let volume = NSBezierPath()
            let lows = NSBezierPath()
            var x = x0
            while x <= x1 {
                let bar = Double(placed.startBar) + Double(x - body.minX) / barWidth
                let levels = TransitionCurves.levels(for: placed, next: next, atBar: bar)
                let volumePoint = CGPoint(x: x, y: body.maxY - 6 - CGFloat(levels.volume) * (body.height - 18))
                let lowPoint = CGPoint(x: x, y: body.maxY - 6 - CGFloat(levels.low) * (body.height - 18))
                if volume.isEmpty {
                    volume.move(to: volumePoint)
                    lows.move(to: lowPoint)
                } else {
                    volume.line(to: volumePoint)
                    lows.line(to: lowPoint)
                }
                x += 2
            }
            volume.lineWidth = 1.5
            NSColor(white: 1, alpha: 0.85).setStroke()
            volume.stroke()
            lows.lineWidth = 1.5
            lows.setLineDash([4, 3], count: 2, phase: 0)
            Theme.waveLow.setStroke()
            lows.stroke()
        }

        for marker in markers(of: clip) {
            Theme.swap.setFill()
            CGRect(x: marker.x - 1, y: body.minY, width: 2, height: body.height).fill()
            let label = NSAttributedString(string: "BASS", attributes: [.font: NSFont.systemFont(ofSize: 8, weight: .heavy), .foregroundColor: NSColor.black])
            let size = label.size()
            let width = size.width + 6
            let x = (marker.x - width / 2).clamped(to: (body.minX + 2)...max(body.minX + 2, body.maxX - width - 2))
            let tag = CGRect(x: x, y: body.minY + 14, width: width, height: size.height + 2)
            NSBezierPath(roundedRect: tag, xRadius: 2, yRadius: 2).fill()
            label.draw(at: CGPoint(x: tag.minX + 3, y: tag.minY + 1))
        }
    }

    private func drawHeader(_ clip: TimelineClip, in header: CGRect) {
        NSColor(white: 1, alpha: 0.05).setFill()
        header.fill()
        var trailing = header.maxX - 6

        if header.width >= 150 {
            let tempo = clip.bpm.map { String(format: "%.1f", $0) }
            let stretch = clip.stretchPercent.map { String(format: "%+.1f%%", $0) }
            let meta = [tempo, stretch, clip.energy.map { "E\($0)" }].compactMap { $0 }.joined(separator: "  ")
            let heavyStretch = abs(clip.stretchPercent ?? 0) > 6
            let metaText = NSAttributedString(string: meta, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: heavyStretch ? NSColor.systemOrange : Theme.secondaryText,
            ])
            trailing -= metaText.size().width
            metaText.draw(at: CGPoint(x: trailing, y: header.minY + 4))
            if let key = clip.key {
                let keyText = NSAttributedString(string: key.description + (clip.keyIsDetected ? "*" : ""), attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.black.withAlphaComponent(0.8),
                ])
                let chip = CGRect(x: trailing - keyText.size().width - 16, y: header.minY + 3, width: keyText.size().width + 10, height: 14)
                Theme.color(for: key).setFill()
                NSBezierPath(roundedRect: chip, xRadius: 3, yRadius: 3).fill()
                keyText.draw(at: CGPoint(x: chip.minX + 5, y: chip.minY + 1))
                trailing = chip.minX
            }
            trailing -= 6
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let title = NSMutableAttributedString(string: clip.title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: Theme.text, .paragraphStyle: paragraph,
        ])
        if let artist = clip.artist {
            title.append(NSAttributedString(string: "  \(artist)", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.secondaryText, .paragraphStyle: paragraph,
            ]))
        }
        let titleRect = CGRect(x: header.minX + 6, y: header.minY + 3, width: max(0, trailing - header.minX - 6), height: 15)
        title.draw(with: titleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func drawCentered(_ text: String, in rect: CGRect, color: NSColor) {
        let string = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: color])
        let size = string.size()
        guard rect.width > size.width + 8 else { return }
        string.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }
}
