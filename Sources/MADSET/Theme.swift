import AppKit
import MADSETCore
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

    /// Three-band waveform, rekordbox style: lows blue, mids amber, highs white.
    static let waveLow = NSColor(srgbRed: 0.16, green: 0.47, blue: 0.98, alpha: 1)
    static let waveMid = NSColor(srgbRed: 0.98, green: 0.62, blue: 0.16, alpha: 0.9)
    static let waveHigh = NSColor(white: 0.95, alpha: 0.85)
    static let kick = NSColor(srgbRed: 1.0, green: 0.26, blue: 0.42, alpha: 0.9)

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
}

extension Phase {
    var label: String { rawValue.uppercased() }
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}
