import MADSETCore
import SwiftUI

/// The set in order, one row per track. Rows drag to reorder; Delete removes the selection.
struct TrackListView: View {
    @Environment(SetStore.self) private var store

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selection) {
            ForEach(Array(store.tracks.enumerated()), id: \.element.id) { index, track in
                TrackRow(position: index + 1, track: track)
                    .tag(track.id)
            }
            .onMove { store.move(fromOffsets: $0, toOffset: $1) }
        }
        .onDeleteCommand {
            if let selection = store.selection { store.remove(selection) }
        }
    }
}

private struct TrackRow: View {
    let position: Int
    let track: Track

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
            Image(systemName: "hourglass").foregroundStyle(.secondary).help("Analizando…")
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
                        .help("Mixed In Key dice \(String(format: "%.0f", tagged)) BPM")
                }
                Text(String(format: "%.1f", value)).font(.system(.caption, design: .monospaced))
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
                .help(detected ? "Key detectada por MADSET (no hay tag de Mixed In Key)" : "Key de Mixed In Key")
        } else {
            Color.clear.frame(width: 36, height: 18)
        }
    }
}
