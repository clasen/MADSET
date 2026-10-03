import MADSETCore
import SwiftUI
import UniformTypeIdentifiers

/// The set in order, one row per track. Rows drag to reorder; Delete removes the selection.
struct TrackListView: View {
    @Bindable var document: SetDocument
    let setBPM: Double

    var body: some View {
        List(selection: $document.selection) {
            ForEach(Array(document.tracks.enumerated()), id: \.element.id) { index, track in
                TrackRow(position: index + 1, track: track, setBPM: setBPM)
                    .tag(track.id)
            }
            .onMove { document.move(fromOffsets: $0, toOffset: $1) }
            .onInsert(of: [.fileURL]) { index, providers in
                FileDrop.loadURLs(from: providers) { document.importItems($0, at: index) }
            }
        }
        .onDeleteCommand {
            if let selection = document.selection { document.remove(selection) }
        }
    }
}

private struct TrackRow: View {
    let position: Int
    let track: Track
    let setBPM: Double

    var body: some View {
        HStack(spacing: 8) {
            Text("\(position)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title).fontWeight(.medium).lineLimit(1)
                Text(track.artist ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            status
            KeyChip(key: track.key, detected: track.keyIsDetected)
            bpm.frame(width: 52, alignment: .trailing)
            Text(track.tags.energy.map { "E\($0)" } ?? "")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
            Text(track.duration.map(formatDuration) ?? "")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var status: some View {
        switch track.status {
        case .reading, .analyzing:
            Image(systemName: "hourglass").foregroundStyle(.secondary).help(String(localized: "Analyzing…"))
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help(message)
        case .ready:
            EmptyView()
        }
    }

    @ViewBuilder private var bpm: some View {
        if let value = track.bpm {
            HStack(spacing: 2) {
                if track.bpmDisagreesWithTag, let tagged = track.tags.bpm {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                        .help(String(localized: "Mixed In Key says \(Int(tagged.rounded())) BPM"))
                }
                Text(String(format: "%.1f", value))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(abs(setBPM / value - 1) > 0.06 ? .orange : .primary)
                    .help(String(localized: "Stretched \(String(format: "%+.1f%%", (setBPM / value - 1) * 100)) to the set tempo"))
            }
        }
    }
}

struct KeyChip: View {
    let key: CamelotKey?
    let detected: Bool

    var body: some View {
        if let key {
            Text(key.description + (detected ? "*" : ""))
                .font(.system(.caption, design: .rounded).weight(.bold))
                .foregroundStyle(.black.opacity(0.8))
                .frame(width: 36, height: 18)
                .background(Color(nsColor: Theme.color(for: key)), in: RoundedRectangle(cornerRadius: 4))
                .help(detected ? String(localized: "Key detected by MADSET (no Mixed In Key tag)") : String(localized: "Key from Mixed In Key"))
        } else {
            Color.clear.frame(width: 36, height: 18)
        }
    }
}

/// File URLs carried by dropped item providers.
enum FileDrop {
    /// Starts loading every provider's URL and calls `completion` on the main actor, in drop order.
    static func loadURLs(from providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        let results = Results(count: providers.count)
        let group = DispatchGroup()
        for (index, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                results.set(url, at: index)
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { completion(results.urls) }
        }
    }

    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var slots: [URL?]

        init(count: Int) { slots = Array(repeating: nil, count: count) }

        func set(_ url: URL?, at index: Int) {
            lock.withLock { slots[index] = url }
        }

        var urls: [URL] { lock.withLock { slots.compactMap { $0 } } }
    }
}
