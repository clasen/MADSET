import AppKit
import BlendlineCore
import SwiftUI

enum Theme {
    static let background = NSColor(srgbRed: 0.075, green: 0.082, blue: 0.098, alpha: 1)
    static let ruler = NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 1)
    static let lane = NSColor(srgbRed: 0.095, green: 0.105, blue: 0.125, alpha: 1)
    static let clip = NSColor(srgbRed: 0.13, green: 0.145, blue: 0.17, alpha: 1)
    static let clipBorder = NSColor(white: 1, alpha: 0.10)
    static let selection = NSColor(srgbRed: 0.35, green: 0.62, blue: 1.0, alpha: 1)
    static let text = NSColor(white: 0.92, alpha: 1)
    static let secondaryText = NSColor(white: 0.58, alpha: 1)

    /// Three-band waveform: lows electric violet, mids rose, highs blush white on top.
    static let waveLow = NSColor(srgbRed: 0.40, green: 0.32, blue: 0.96, alpha: 1)
    static let waveMid = NSColor(srgbRed: 0.95, green: 0.31, blue: 0.60, alpha: 0.88)
    static let waveHigh = NSColor(srgbRed: 1.0, green: 0.84, blue: 0.91, alpha: 0.85)
    static let kick = NSColor(srgbRed: 1.0, green: 0.26, blue: 0.42, alpha: 0.9)
    static let playhead = NSColor(srgbRed: 1.0, green: 0.84, blue: 0.2, alpha: 1)
    /// The monitor head and the controls that preview through the monitor output.
    static let monitor = NSColor(srgbRed: 0.25, green: 0.92, blue: 0.82, alpha: 1)
    static let swap = NSColor(srgbRed: 0.98, green: 0.62, blue: 0.16, alpha: 1)

    /// Surfaces of the SwiftUI panels around the timeline, from the window down to raised controls.
    static let window = Color(nsColor: NSColor(srgbRed: 0.055, green: 0.06, blue: 0.07, alpha: 1))
    static let panel = Color(nsColor: NSColor(srgbRed: 0.09, green: 0.097, blue: 0.113, alpha: 1))
    static let control = Color(nsColor: NSColor(srgbRed: 0.15, green: 0.16, blue: 0.185, alpha: 1))
    static let controlHover = Color(nsColor: NSColor(srgbRed: 0.19, green: 0.2, blue: 0.23, alpha: 1))
    static let hairline = Color.white.opacity(0.08)
    static let accent = Color(nsColor: NSColor(srgbRed: 1.0, green: 0.6, blue: 0.12, alpha: 1))
    static let play = Color(nsColor: NSColor(srgbRed: 0.3, green: 0.85, blue: 0.4, alpha: 1))
    /// Deck A plays the first timeline lane, deck B the second.
    static let decks = [
        Color(nsColor: NSColor(srgbRed: 0.2, green: 0.56, blue: 1.0, alpha: 1)),
        Color(nsColor: NSColor(srgbRed: 1.0, green: 0.33, blue: 0.45, alpha: 1)),
    ]

    static func color(for phase: Phase) -> NSColor {
        switch phase {
        case .intro: NSColor(srgbRed: 0.36, green: 0.49, blue: 0.69, alpha: 1)
        case .groove: NSColor(srgbRed: 0.17, green: 0.70, blue: 0.64, alpha: 1)
        case .buildup: NSColor(srgbRed: 0.95, green: 0.64, blue: 0.23, alpha: 1)
        case .drop: NSColor(srgbRed: 0.91, green: 0.27, blue: 0.37, alpha: 1)
        case .breakdown: NSColor(srgbRed: 0.56, green: 0.42, blue: 0.85, alpha: 1)
        case .outro: NSColor(srgbRed: 0.43, green: 0.48, blue: 0.54, alpha: 1)
        }
    }

    /// Camelot wheel: neighbouring numbers get neighbouring hues, minor (A) a little darker.
    static func color(for key: CamelotKey) -> NSColor {
        let hue = (Double(key.number - 1) / 12 + 0.42).truncatingRemainder(dividingBy: 1)
        return NSColor(hue: hue, saturation: 0.62, brightness: key.mode == .minor ? 0.78 : 0.95, alpha: 1)
    }

    /// Mixed In Key energy 1–10 from pale cyan through blue and violet to saturated magenta,
    /// so the crowded middle (5–8) still lands on clearly different hues.
    static func color(forEnergy energy: Int) -> NSColor {
        let t = Double(min(max(energy, 1), 10) - 1) / 9
        return NSColor(hue: 0.5 + 0.39 * t, saturation: 0.35 + 0.4 * t, brightness: 0.96, alpha: 1)
    }
}

extension Phase {
    var label: String { rawValue.uppercased() }
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}
