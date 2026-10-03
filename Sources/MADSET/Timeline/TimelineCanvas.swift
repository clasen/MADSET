import AppKit
import MADSETCore

/// The set on a horizontal time axis at the set tempo, in two lanes like two decks; transitions are
/// where consecutive tracks overlap.
///
/// - Scroll pans; ⌘/⌥-scroll or pinch zooms around the pointer.
/// - Drag a clip's header to reorder; drag its body to change where it enters (snaps to phrases, ⌥ to bars).
/// - Drag the BASS marker to move the bass swap; click the ruler to move the playhead.
final class TimelineCanvas: NSView {
    var clips: [TimelineClip] = [] {
        didSet {
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
    var onSetOverlap: (Track.ID, Int) -> Void = { _, _ in }
    var onSetBassSwap: (Track.ID, Int) -> Void = { _, _ in }
    var onSeek: (TimeInterval) -> Void = { _ in }
    var playhead: () -> (time: TimeInterval, isPlaying: Bool) = { (0, false) }

    private var origin: TimeInterval = 0
    private var pointsPerSecond: Double = 1
    private var userHasNavigated = false
    private var isSelectingFromCanvas = false
    private var gesture: Gesture?
    private var displayLink: CADisplayLink?
    private var drawnPlayhead: TimeInterval = 0

    private enum Gesture {
        case reorder(id: Track.ID, startX: CGFloat, offset: CGFloat)
        case shift(id: Track.ID, startX: CGFloat, original: Int, maximum: Int, overlap: Int)
        case swap(id: Track.ID, startX: CGFloat, original: Int, overlap: Int, swap: Int)
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

    private var setDuration: TimeInterval { clips.map(\.end).max() ?? 0 }

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

    private func revealSelection() {
        guard let clip = clips.first(where: { $0.id == selectedID }) else { return }
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
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
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
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
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
        let followX = x(for: time)
        if isPlaying, gesture == nil, followX > bounds.width * 0.85 || followX < 0 {
            origin = time - visibleSpan * 0.1
            needsDisplay = true
        } else {
            setNeedsDisplay(playheadRect(at: drawnPlayhead))
            setNeedsDisplay(playheadRect(at: time))
        }
        drawnPlayhead = time
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
        guard let index = clips.lastIndex(where: { rect(for: $0).contains(point) }) else {
            select(nil)
            return
        }
        let clip = clips[index]
        select(clip.id)

        if let marker = swapMarker(at: point) {
            let owner = marker.owner.placed
            gesture = .swap(id: owner.id, startX: point.x, original: owner.bassSwapBar, overlap: owner.overlapBars, swap: owner.bassSwapBar)
        } else if point.y < rect(for: clip).minY + Self.headerHeight || clip.isFirst {
            gesture = .reorder(id: clip.id, startX: point.x, offset: 0)
        } else {
            let previous = clips[index - 1]
            let maximum = max(0, min(previous.placed.lengthBars, clip.placed.lengthBars) - 1)
            gesture = .shift(id: clip.id, startX: point.x, original: clip.placed.overlapBars, maximum: maximum, overlap: clip.placed.overlapBars)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        let barWidth = CGFloat((clips.first?.barDuration ?? 1) * pointsPerSecond)
        let snap = event.modifierFlags.contains(.option) ? 1 : phraseBars
        switch gesture {
        case .reorder(let id, let startX, _):
            gesture = .reorder(id: id, startX: startX, offset: x - startX)
        case .shift(let id, let startX, let original, let maximum, _):
            let movedBars = Double((x - startX) / barWidth)
            let snapped = Int((movedBars / Double(snap)).rounded()) * snap
            gesture = .shift(id: id, startX: startX, original: original, maximum: maximum, overlap: (original - snapped).clamped(to: 0...maximum))
        case .swap(let id, let startX, let original, let overlap, _):
            let moved = Int(Double((x - startX) / barWidth).rounded())
            gesture = .swap(id: id, startX: startX, original: original, overlap: overlap, swap: (original + moved).clamped(to: 0...overlap))
        case nil:
            return
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            gesture = nil
            needsDisplay = true
        }
        switch gesture {
        case .reorder(let id, _, let offset) where abs(offset) > Self.dragThreshold:
            onMove(id, dropTarget(for: id, offset: offset)?.id)
        case .shift(let id, _, let original, _, let overlap) where overlap != original:
            onSetOverlap(id, overlap)
        case .swap(let id, _, let original, _, let swap) where swap != original:
            onSetBassSwap(id, swap)
        default:
            break
        }
    }

    override func resetCursorRects() {
        for clip in clips {
            let body = bodyRect(for: clip)
            guard body.intersects(bounds) else { continue }
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
        guard let clip = clips.first(where: { $0.id == id }) else { return nil }
        let center = clip.center + Double(offset) / pointsPerSecond
        return clips.first { $0.id != id && $0.center > center }
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
        switch gesture {
        case .reorder(let id, _, let offset) where id == clip.id:
            r.origin.x += offset
        case .shift(let id, _, let original, _, let overlap) where id == clip.id:
            r.origin.x += CGFloat(Double(original - overlap) * clip.barDuration * pointsPerSecond)
        default:
            break
        }
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

    /// Bass-swap markers drawn on a clip: its own transition in and the next track's, with the clip each one edits.
    private func markers(of clip: TimelineClip) -> [(x: CGFloat, owner: TimelineClip)] {
        var result: [(x: CGFloat, owner: TimelineClip)] = []
        let r = rect(for: clip)
        let barWidth = clip.barDuration * pointsPerSecond
        let placed = previewPlacement(of: clip)
        func detailed(_ overlap: Int) -> Bool { CGFloat(Double(overlap) * barWidth) >= Self.detailedTransitionWidth }
        if !clip.isFirst, placed.overlapBars > 0, detailed(placed.overlapBars) {
            result.append((r.minX + CGFloat(Double(placed.bassSwapBar) * barWidth), clip))
        }
        if let next = clip.next, next.overlapBars > 0, detailed(next.overlapBars), let owner = clips.first(where: { $0.id == next.id }) {
            let ownerPlacement = previewPlacement(of: owner)
            let bar = Double(ownerPlacement.startBar + ownerPlacement.bassSwapBar - placed.startBar)
            result.append((r.minX + CGFloat(bar * barWidth), owner))
        }
        return result
    }

    private func swapMarker(at point: CGPoint) -> (x: CGFloat, owner: TimelineClip)? {
        for clip in clips.reversed() where bodyRect(for: clip).contains(point) {
            if let marker = markers(of: clip).first(where: { abs($0.x - point.x) <= Self.markerHitWidth }) { return marker }
        }
        return nil
    }

    /// The clip's placement as a drag in progress would leave it.
    private func previewPlacement(of clip: TimelineClip) -> PlacedEntry {
        let p = clip.placed
        switch gesture {
        case .shift(let id, _, let original, _, let overlap) where id == clip.id:
            return PlacedEntry(id: p.id, file: p.file, startBar: p.startBar + original - overlap, cueInBar: p.cueInBar, cueOutBar: p.cueOutBar,
                               overlapBars: overlap, bassSwapBar: min(p.bassSwapBar, overlap), grid: p.grid)
        case .swap(let id, _, _, _, let swap) where id == clip.id:
            return PlacedEntry(id: p.id, file: p.file, startBar: p.startBar, cueInBar: p.cueInBar, cueOutBar: p.cueOutBar,
                               overlapBars: p.overlapBars, bassSwapBar: swap, grid: p.grid)
        default:
            return p
        }
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

        let dragged: Track.ID? = switch gesture {
        case .reorder(let id, _, _), .shift(let id, _, _, _, _): id
        default: nil
        }
        for clip in clips where clip.id != dragged && rect(for: clip).intersects(dirtyRect) {
            drawClip(clip, in: context, dirtyRect: dirtyRect)
        }
        if let dragged, let clip = clips.first(where: { $0.id == dragged }) {
            if case .reorder(let id, _, let offset) = gesture {
                let markerX = dropTarget(for: id, offset: offset).map { x(for: $0.start) } ?? x(for: setDuration)
                Theme.selection.setFill()
                CGRect(x: markerX - 1.5, y: Self.rulerHeight, width: 3, height: bounds.height - Self.rulerHeight).fill()
            }
            drawClip(clip, in: context, dirtyRect: dirtyRect, alpha: 0.9)
        }
        drawPlayhead(dirtyRect)
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
        let end = min(body.maxX, dirtyRect.maxX)
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
                while x < end {
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
        let placed = previewPlacement(of: clip)
        let next = clip.next.flatMap { next in clips.first { $0.id == next.id } }.map(previewPlacement)
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
            let tag = CGRect(x: marker.x - size.width / 2 - 3, y: body.minY + 14, width: size.width + 6, height: size.height + 2)
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

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
