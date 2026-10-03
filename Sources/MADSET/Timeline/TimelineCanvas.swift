import AppKit
import MADSETCore

/// The set laid out on a horizontal time axis, two lanes like two decks.
/// Scroll pans, ⌘/⌥-scroll or pinch zooms around the pointer, dragging a clip reorders the set.
final class TimelineCanvas: NSView {
    var clips: [TimelineClip] = [] {
        didSet {
            if !userHasNavigated, oldValue.last?.end != clips.last?.end { fitAll() }
            needsDisplay = true
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

    /// Time at the left edge and horizontal scale.
    private var origin: TimeInterval = 0
    private var pointsPerSecond: Double = 1
    private var userHasNavigated = false
    private var isSelectingFromCanvas = false
    private var drag: Drag?

    private struct Drag {
        let id: Track.ID
        let startX: CGFloat
        var offset: CGFloat = 0
    }

    private static let rulerHeight: CGFloat = 24
    private static let headerHeight: CGFloat = 20
    private static let lanePadding: CGFloat = 8
    private static let zoomRange: ClosedRange<Double> = 0.02...400
    private static let dragThreshold: CGFloat = 4

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var setDuration: TimeInterval { clips.last?.end ?? 0 }

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

    private func revealSelection() {
        guard let clip = clips.first(where: { $0.id == selectedID }) else { return }
        let visible = time(for: 0)...time(for: bounds.width)
        guard clip.start < visible.lowerBound || clip.end > visible.upperBound else { return }
        let span = visible.upperBound - visible.lowerBound
        origin = clip.duration < span * 0.9 ? clip.center - span / 2 : clip.start - span * 0.05
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
    }

    private func clampOrigin() {
        let margin = Double(bounds.width) / pointsPerSecond * 0.5
        origin = origin.clamped(to: -margin...max(-margin, setDuration - margin))
    }

    // MARK: - Selection and reordering

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let hit = clips.last { rect(for: $0).contains(point) }
        isSelectingFromCanvas = true
        selectedID = hit?.id
        isSelectingFromCanvas = false
        onSelect(hit?.id)
        drag = hit.map { Drag(id: $0.id, startX: point.x) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard var current = drag else { return }
        current.offset = convert(event.locationInWindow, from: nil).x - current.startX
        drag = current
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            drag = nil
            needsDisplay = true
        }
        guard let drag, abs(drag.offset) > Self.dragThreshold else { return }
        onMove(drag.id, dropTarget(for: drag)?.id)
    }

    /// The clip the dragged one would be inserted before; nil means the end of the set.
    private func dropTarget(for drag: Drag) -> TimelineClip? {
        guard let clip = clips.first(where: { $0.id == drag.id }) else { return nil }
        let center = clip.center + Double(drag.offset) / pointsPerSecond
        return clips.first { $0.id != drag.id && $0.center > center }
    }

    // MARK: - Geometry

    private func x(for time: TimeInterval) -> CGFloat { CGFloat((time - origin) * pointsPerSecond) }
    private func time(for x: CGFloat) -> TimeInterval { origin + Double(x) / pointsPerSecond }

    private var laneHeight: CGFloat {
        max(48, (bounds.height - Self.rulerHeight - Self.lanePadding * 3) / 2)
    }

    private func laneRect(_ lane: Int) -> CGRect {
        CGRect(x: 0, y: Self.rulerHeight + Self.lanePadding + CGFloat(lane) * (laneHeight + Self.lanePadding), width: bounds.width, height: laneHeight)
    }

    private func rect(for clip: TimelineClip) -> CGRect {
        let lane = laneRect(clip.lane)
        var r = CGRect(x: x(for: clip.start), y: lane.minY, width: CGFloat(clip.duration * pointsPerSecond), height: lane.height)
        if let drag, drag.id == clip.id { r.origin.x += drag.offset }
        return r
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

        for clip in clips where clip.id != drag?.id && rect(for: clip).intersects(dirtyRect) {
            drawClip(clip, in: context, dirtyRect: dirtyRect)
        }
        if let drag, let dragged = clips.first(where: { $0.id == drag.id }) {
            let markerX = dropTarget(for: drag).map { x(for: $0.start) } ?? x(for: setDuration)
            Theme.selection.setFill()
            CGRect(x: markerX - 1.5, y: Self.rulerHeight, width: 3, height: bounds.height - Self.rulerHeight).fill()
            drawClip(dragged, in: context, dirtyRect: dirtyRect, alpha: 0.85)
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
        let body = CGRect(x: r.minX, y: header.maxY, width: r.width, height: r.height - header.height)
        if let analysis = clip.analysis {
            drawSections(analysis, clipRect: r, body: body)
            drawGrid(analysis, clipRect: r, body: body, dirtyRect: dirtyRect)
            drawWaveform(analysis.waveform, body: body, dirtyRect: dirtyRect)
            drawKicks(analysis, clipRect: r, body: body)
        } else {
            drawCentered(clip.failure.map { "Error: \($0)" } ?? "Analizando…", in: body, color: clip.failure == nil ? Theme.secondaryText : .systemRed)
        }
        drawHeader(clip, in: header)
        context.restoreGState()

        let selected = clip.id == selectedID
        (selected ? Theme.selection : Theme.clipBorder).setStroke()
        shape.lineWidth = selected ? 2 : 1
        shape.stroke()
    }

    private func drawSections(_ analysis: TrackAnalysis, clipRect r: CGRect, body: CGRect) {
        let grid = analysis.grid
        let labelAttributes: (Phase) -> [NSAttributedString.Key: Any] = {
            [.font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: Theme.color(for: $0)]
        }
        for (index, section) in analysis.sections.enumerated() {
            let x0 = index == 0 ? r.minX : r.minX + CGFloat(grid.barStart(section.startBar) * pointsPerSecond)
            let x1 = index == analysis.sections.count - 1 ? r.maxX : r.minX + CGFloat(grid.barStart(section.endBar) * pointsPerSecond)
            let band = CGRect(x: x0, y: body.minY, width: x1 - x0, height: body.height)
            Theme.color(for: section.phase).withAlphaComponent(0.16).setFill()
            band.fill()
            if band.width >= 64 {
                NSAttributedString(string: section.phase.label, attributes: labelAttributes(section.phase))
                    .draw(at: CGPoint(x: band.minX + 4, y: body.minY + 2))
            }
        }
    }

    private func drawGrid(_ analysis: TrackAnalysis, clipRect r: CGRect, body: CGRect, dirtyRect: CGRect) {
        let grid = analysis.grid
        let barWidth = grid.barDuration * pointsPerSecond
        let beatWidth = grid.beatDuration * pointsPerSecond
        let phraseBars = AppConfig.current.analysis.phraseBars
        guard barWidth * Double(phraseBars) >= 6 else { return }

        let visibleStart = Double(max(r.minX, dirtyRect.minX) - r.minX) / pointsPerSecond
        let visibleEnd = Double(min(r.maxX, dirtyRect.maxX) - r.minX) / pointsPerSecond
        func line(at t: TimeInterval, alpha: CGFloat) {
            NSColor(white: 1, alpha: alpha).setFill()
            CGRect(x: r.minX + CGFloat(t * pointsPerSecond), y: body.minY, width: 1, height: body.height).fill()
        }
        var bar = max(0, Int(((visibleStart - grid.firstDownbeat) / grid.barDuration).rounded(.down)))
        while grid.barStart(bar) <= visibleEnd {
            let isPhrase = (bar - grid.phraseOffsetBars) % phraseBars == 0
            if isPhrase {
                line(at: grid.barStart(bar), alpha: 0.32)
            } else if barWidth >= 6 {
                line(at: grid.barStart(bar), alpha: 0.12)
            }
            if beatWidth >= 10 {
                for beat in 1..<4 { line(at: grid.barStart(bar) + Double(beat) * grid.beatDuration, alpha: 0.05) }
            }
            bar += 1
        }
    }

    private func drawWaveform(_ waveform: Waveform, body: CGRect, dirtyRect: CGRect) {
        let start = max(body.minX, dirtyRect.minX).rounded(.down)
        let end = min(body.maxX, dirtyRect.maxX)
        guard end > start, waveform.count > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        let middle = body.midY
        let halfHeight = body.height / 2 - 6
        let pointsPerColumn = waveform.pointsPerSecond / pointsPerSecond

        let bands: [(Data, NSColor, CGFloat)] = [(waveform.low, Theme.waveLow, 1), (waveform.mid, Theme.waveMid, 0.72), (waveform.high, Theme.waveHigh, 0.45)]
        for (data, color, scale) in bands {
            var tops: [CGPoint] = []
            data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                var x = start
                while x < end {
                    let first = Int(Double(x - body.minX) * pointsPerColumn)
                    let last = min(waveform.count, max(first + 1, Int(Double(x + 1 - body.minX) * pointsPerColumn)))
                    // Zoomed out, a column spans many points: their mean keeps the track's dynamics
                    // readable where the maximum would saturate.
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

    private func drawKicks(_ analysis: TrackAnalysis, clipRect r: CGRect, body: CGRect) {
        let grid = analysis.grid
        Theme.kick.setFill()
        let barWidth = CGFloat(grid.barDuration * pointsPerSecond)
        for (bar, presence) in analysis.kickPresence.enumerated() where presence >= 0.5 {
            let x = r.minX + CGFloat(grid.barStart(bar) * pointsPerSecond)
            CGRect(x: x, y: body.maxY - 4, width: max(1, barWidth - (barWidth > 4 ? 1 : 0)), height: 3).fill()
        }
    }

    private func drawHeader(_ clip: TimelineClip, in header: CGRect) {
        NSColor(white: 1, alpha: 0.05).setFill()
        header.fill()
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        var trailing = header.maxX - 6

        if header.width >= 150 {
            let meta = [clip.bpm.map { String(format: "%.1f", $0) }, clip.energy.map { "E\($0)" }].compactMap { $0 }.joined(separator: "  ")
            let metaText = NSAttributedString(string: meta, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium), .foregroundColor: Theme.secondaryText,
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
        let title = NSMutableAttributedString(string: clip.title, attributes: [.font: font, .foregroundColor: Theme.text, .paragraphStyle: paragraph])
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
