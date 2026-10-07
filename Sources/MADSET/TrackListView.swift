import MADSETCore
import SwiftUI
import UniformTypeIdentifiers

/// A set in order, one row per track, under a library-style header whose first button folds out
/// the sets sidebar and, when the set isn't the loaded one, whose last loads it. Rows also drag
/// out as their files, to add them to another set. Selected rows drag together
/// to reorder; their context menu moves them to either end, orders them (the whole set for a single
/// row) or removes them, as does ⌘⌫ (see `ContentView`).
struct TrackListView: View {
    @Bindable var document: SetDocument
    let layout: SetLayout
    /// Whether the set is the one in the timeline and decks.
    let isLoaded: Bool
    @Binding var showsSidebar: Bool
    let load: () -> Void
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(showsSidebar ? "Hide Sets" : "Show Sets", systemImage: "sidebar.left") { showsSidebar.toggle() }
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(showsSidebar ? Theme.accent : .secondary)
                    .keyboardShortcut("s", modifiers: [.command, .control])
                    .help(showsSidebar ? String(localized: "Hide your sets and groups (⌃⌘S)") : String(localized: "Show your sets and groups (⌃⌘S)"))
                Text(document.fileURL.deletingPathExtension().lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(summary).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                if !isLoaded {
                    Button("Load", systemImage: "square.and.arrow.up.on.square", action: load)
                        .controlSize(.small)
                        .help(String(localized: "Load into the timeline and decks"))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Theme.panel)
            Divider()
            if document.tracks.isEmpty { emptySet } else { list }
        }
    }

    /// Takes drops itself: an empty list has no row to insert at, so it would turn them away.
    private var emptySet: some View {
        ContentUnavailableView("Drop tracks or folders here", systemImage: "square.and.arrow.down")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isDropTargeted ? Theme.controlHover : Theme.window)
            .dropDestination(for: URL.self) { urls, _ in
                document.importItems(urls)
                return !urls.isEmpty
            } isTargeted: { isDropTargeted = $0 }
    }

    private var list: some View {
        List(selection: $document.selection) {
            Section {
                let split = splitFiles
                ForEach(Array(document.tracks.enumerated()), id: \.element.id) { index, track in
                    let placed = layout.entries[index]
                    TrackRow(position: index + 1, track: track, part: split.contains(track.url) ? placed.cueInBar..<placed.cueOutBar : nil,
                             setBPM: layout.bpm, isPlaying: document.nowPlaying.contains(track.id))
                        .tag(track.id)
                        // Lets rows drag out, onto a set in the sidebar or the timeline, as their files.
                        .itemProvider { NSItemProvider(object: track.url as NSURL) }
                }
                .onMove { document.move(fromOffsets: $0, toOffset: $1) }
                .onInsert(of: [.fileURL]) { index, providers in
                    FileDrop.loadURLs(from: providers) { document.importItems($0, at: index) }
                }
            } header: {
                ColumnHeader()
            }
        }
        .contextMenu(forSelectionType: Track.ID.self) { ids in
            if !ids.isEmpty {
                if ids.count == 1, let id = ids.first {
                    Button("Move Playhead to Track Start") { document.seek(toStartOf: id) }
                    Divider()
                }
                Button("Move to Start") { document.moveToStart(ids) }
                Button("Move to End") { document.move(ids, before: nil) }
                Menu(ids.count < 2 ? String(localized: "Order Set") : String(localized: "Order \(ids.count) Tracks")) {
                    ForEach(SetOrder.Criterion.allCases, id: \.self) { criterion in
                        Button(criterion.title) { document.order(ids, by: criterion) }
                    }
                }
                Divider()
                Button(ids.count == 1 ? String(localized: "Remove Track") : String(localized: "Remove \(ids.count) Tracks")) { document.remove(ids) }
                    .keyboardShortcut(.delete, modifiers: .command)
            }
        }
        .listStyle(.plain)
        .alternatingRowBackgrounds()
        .scrollContentBackground(.hidden)
        .background(Theme.window)
    }

    /// Files that play in more than one part of the set.
    private var splitFiles: Set<URL> {
        var seen = Set<URL>()
        return Set(document.tracks.map(\.url).filter { !seen.insert($0).inserted })
    }

    private var summary: String {
        guard !document.tracks.isEmpty else { return String(localized: "Empty set") }
        var parts = [String(localized: "\(document.tracks.count) tracks"), formatDuration(layout.duration)]
        if document.pendingCount > 0 { parts.append(String(localized: "analyzing \(document.pendingCount)…")) }
        return parts.joined(separator: " · ")
    }
}

/// Widths shared by the column header and the rows.
private enum TrackColumns {
    static let position: CGFloat = 26
    static let playing: CGFloat = 16
    static let key: CGFloat = 38
    static let energy: CGFloat = 26
    static let bpm: CGFloat = 64
    static let time: CGFloat = 44
    static let status: CGFloat = 16
    static let spacing: CGFloat = 8
    static let genre: CGFloat = 150
    /// Extra space between a cell's text and the list's side edges.
    static let cellInset: CGFloat = 12
    /// A list section header ends this much before its rows do (room AppKit keeps for its Show/Hide button).
    static let headerTrailingInset: CGFloat = 24
}

private struct ColumnHeader: View {
    var body: some View {
        HStack(spacing: TrackColumns.spacing) {
            Text("#").frame(width: TrackColumns.position, alignment: .trailing)
            Color.clear.frame(width: TrackColumns.playing)
            Text("Key").frame(width: TrackColumns.key)
            Text("E").frame(width: TrackColumns.energy).help(String(localized: "Energy (Mixed In Key; * estimated by MADSET)"))
            Text("Title").frame(maxWidth: .infinity, alignment: .leading)
            Text("Artist").frame(maxWidth: .infinity, alignment: .leading)
            Text("Genre").frame(width: TrackColumns.genre, alignment: .leading)
            Text("BPM").frame(width: TrackColumns.bpm, alignment: .trailing)
            Text("Time").frame(width: TrackColumns.time, alignment: .trailing)
            Color.clear.frame(width: TrackColumns.status)
        }
        .padding(.horizontal, TrackColumns.cellInset)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.trailing, -TrackColumns.headerTrailingInset)
        .frame(height: 22)
    }
}

private struct TrackRow: View {
    let position: Int
    let track: Track
    /// The track's bars this row plays, when the track is split.
    let part: Range<Int>?
    let setBPM: Double
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: TrackColumns.spacing) {
            Text("\(position)")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: TrackColumns.position, alignment: .trailing)
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.accent)
                .frame(width: TrackColumns.playing)
                .opacity(isPlaying ? 1 : 0)
            KeyChip(key: track.key, detected: track.keyIsDetected)
                .frame(width: TrackColumns.key)
            EnergyChip(energy: track.energy, detected: track.energyIsDetected)
                .frame(width: TrackColumns.energy)
            HStack(spacing: 6) {
                Text(track.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isPlaying ? Theme.accent : .primary)
                    .lineLimit(1)
                if let part {
                    Text("bars \(part.lowerBound)–\(part.upperBound)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .help(String(localized: "Part of a split track"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(track.artist ?? "")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(track.genre ?? "")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: TrackColumns.genre, alignment: .leading)
            bpm.frame(width: TrackColumns.bpm, alignment: .trailing)
            Text(track.duration.map(formatDuration) ?? "")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: TrackColumns.time, alignment: .trailing)
            status.frame(width: TrackColumns.status)
        }
        .padding(.horizontal, TrackColumns.cellInset)
        .frame(height: 26)
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
            Text(String(format: "%.1f", value))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(abs(setBPM / value - 1) > 0.06 ? .orange : .primary)
                .help(String(localized: "Stretched \(String(format: "%+.1f%%", (setBPM / value - 1) * 100)) to the set tempo"))
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

struct EnergyChip: View {
    let energy: Int?
    let detected: Bool

    var body: some View {
        if let energy {
            Text("\(energy)" + (detected ? "*" : ""))
                .font(.system(.caption, design: .rounded).weight(.bold).monospacedDigit())
                .foregroundStyle(.black.opacity(0.8))
                .frame(width: 24, height: 18)
                .background(Color(nsColor: Theme.color(forEnergy: energy)), in: RoundedRectangle(cornerRadius: 4))
                .help(detected ? String(localized: "Energy \(energy) estimated by MADSET (no Mixed In Key tag)") : String(localized: "Energy \(energy) (Mixed In Key)"))
        } else {
            Color.clear.frame(width: 24, height: 18)
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
