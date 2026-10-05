import AppKit
import MADSETCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var document: SetDocument
    @Environment(\.undoManager) private var undoManager
    @State private var isDropTargeted = false
    @State private var fitRequest = 0
    @AppStorage("showsDecks") private var showsDecks = true
    @AppStorage("followsPlayhead") private var followsPlayhead = true
    @AppStorage("trackListHeight") private var trackListHeight = 260.0
    @AppStorage("showsSetsSidebar") private var showsSetsSidebar = false
    @State private var timelineHeight: CGFloat = 0
    @State private var listHeight: CGFloat = 0

    private static let minTimelineHeight: CGFloat = 200
    private static let minTrackListHeight: CGFloat = 150

    var body: some View {
        let layout = document.layout
        let clips = TimelineClip.clips(for: layout, tracks: document.tracks)
        VStack(spacing: 0) {
            TimelineView(document: document, clips: clips, fitRequest: fitRequest, followsPlayhead: $followsPlayhead)
                .overlay {
                    if document.tracks.isEmpty {
                        ContentUnavailableView("Drop tracks or folders here", systemImage: "square.and.arrow.down",
                                               description: Text("MP3, AIFF, WAV, FLAC or M4A. Tempo, beatgrid, kick, phases and key are analyzed."))
                            .allowsHitTesting(false)
                    }
                }
                .frame(minHeight: Self.minTimelineHeight, maxHeight: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { timelineHeight = $0 }
            if showsDecks {
                Divider()
                DeckPanel(document: document, clips: clips, layout: layout)
            }
            Divider()
            TransitionInspector(document: document, layout: layout)
            PaneSplitter { start, offset in
                trackListHeight = min(max(start.list - offset, Self.minTrackListHeight), start.list + start.timeline - Self.minTimelineHeight)
            } heights: { (list: listHeight, timeline: timelineHeight) }
            // The list takes its height first and gives it back only once the timeline is at its minimum.
            HSplitView {
                if showsSetsSidebar {
                    SetsSidebar()
                        .frame(minWidth: 180, idealWidth: 230, maxWidth: 300)
                }
                TrackListView(document: document, layout: layout, showsSidebar: $showsSetsSidebar)
                    .frame(minWidth: 500)
            }
                .frame(minHeight: Self.minTrackListHeight, maxHeight: max(trackListHeight, Self.minTrackListHeight))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                .layoutPriority(1)
        }
        .background(Theme.window)
        .background(PlaybackTicker(document: document))
        .background(KeyMonitor(keyCode: KeyMonitor.space, modifiers: []) { document.togglePlayback() })
        // ⌘ so a stray Delete never drops a track; the selection is shared by the list and the timeline.
        .background(KeyMonitor(keyCode: KeyMonitor.delete, modifiers: .command) {
            document.remove(document.selection)
        })
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3).padding(4).allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            document.importItems(urls)
            return !urls.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                if !showsDecks { CompactTransport(document: document, duration: layout.duration) }
            }
            ToolbarItemGroup {
                Button(showsDecks ? "Hide Decks" : "Show Decks", systemImage: "rectangle.split.2x1") { showsDecks.toggle() }
                    .keyboardShortcut("d", modifiers: [.command, .option])
                    .help(showsDecks ? String(localized: "Hide the decks (⌥⌘D)") : String(localized: "Show the decks (⌥⌘D)"))
                Button("Import", systemImage: "plus") { document.importItems(ImportPanel.choose()) }
                    .help(String(localized: "Add tracks or folders to the end of the set (⌘I)"))
                Button("Fit", systemImage: "arrow.left.and.right.square") { fitRequest += 1 }
                    .help(String(localized: "Show the whole set"))
                Toggle("Follow Playhead", systemImage: "arrow.right.to.line", isOn: $followsPlayhead)
                    .keyboardShortcut("f", modifiers: [.command, .option])
                    .help(String(localized: "Scroll the timeline along with the playhead while playing (⌥⌘F)"))
            }
        }
        .alert("Playback is not available", isPresented: Binding(get: { document.playbackError != nil }, set: { if !$0 { document.clearPlaybackError() } })) {
            Button("OK") {}
        } message: {
            Text(document.playbackError ?? "")
        }
        .alert("The mix could not be exported", isPresented: Binding(get: { document.exportError != nil }, set: { if !$0 { document.clearExportError() } })) {
            Button("OK") {}
        } message: {
            Text(document.exportError ?? "")
        }
        .alert(duplicatesTitle, isPresented: Binding(get: { document.pendingImport != nil }, set: { if !$0 { document.cancelImport() } })) {
            Button("Skip Duplicates") { document.resolveImport(skippingDuplicates: true) }
                .keyboardShortcut(.defaultAction)
            Button("Add All") { document.resolveImport(skippingDuplicates: false) }
            Button("Cancel", role: .cancel) { document.cancelImport() }
        } message: {
            Text(duplicatesMessage)
        }
        .sheet(isPresented: Binding(get: { document.exportProgress != nil }, set: { _ in })) {
            ExportProgressSheet(progress: document.exportProgress ?? 0) { document.cancelExport() }
        }
        .alert("The set could not be saved", isPresented: Binding(get: { document.saveError != nil }, set: { if !$0 { document.clearSaveError() } })) {
            Button("OK") {}
        } message: {
            Text(document.saveError ?? "")
        }
        .focusedSceneValue(\.setDocument, document)
        // The window stays while the sidebar swaps sets: each new one gets the undo manager and a fitted view.
        .onChange(of: ObjectIdentifier(document), initial: true) {
            document.undoManager = undoManager
            fitRequest += 1
        }
        .onChange(of: undoManager) { document.undoManager = undoManager }
    }
}

extension ContentView {
    private var duplicatesTitle: String {
        let count = document.pendingImport?.duplicates.count ?? 0
        return count == 1 ? String(localized: "1 track is already in the set") : String(localized: "\(count) tracks are already in the set")
    }

    private var duplicatesMessage: String {
        guard let pending = document.pendingImport else { return "" }
        let titles = pending.tracks.filter { pending.duplicates.contains($0.id) }.map(\.title)
        let shown = titles.prefix(Self.listedDuplicates).joined(separator: "\n")
        return titles.count > Self.listedDuplicates ? shown + "\n" + String(localized: "and \(titles.count - Self.listedDuplicates) more") : shown
    }

    private static let listedDuplicates = 5
}

extension FocusedValues {
    @Entry var setDocument: SetDocument?
}

enum ImportPanel {
    @MainActor
    static func choose() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio]
        panel.prompt = String(localized: "Add to Set")
        return panel.runModal() == .OK ? panel.urls : []
    }
}

enum ExportPanel {
    /// Where to write a mix in `format`, named after the set.
    @MainActor
    static func choose(_ format: SetExporter.Format) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = NSApp.keyWindow?.title ?? String(localized: "Mix")
        panel.prompt = String(localized: "Export")
        return panel.runModal() == .OK ? panel.url : nil
    }
}

private struct ExportProgressSheet: View {
    let progress: Double
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Exporting mix…").font(.headline)
            ProgressView(value: progress)
            HStack {
                Text(progress, format: .percent.precision(.fractionLength(0))).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 340)
        .interactiveDismissDisabled()
    }
}

/// Polls the playhead so the document follows it, with or without the decks.
private struct PlaybackTicker: View {
    let document: SetDocument

    var body: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            Color.clear.task(id: document.currentTime) { document.playbackTick() }
        }
    }
}

/// Play and the clock in the toolbar while the decks, which carry them, are hidden.
private struct CompactTransport: View {
    let document: SetDocument
    let duration: TimeInterval

    var body: some View {
        Button(document.isPlaying ? "Pause" : "Play", systemImage: document.isPlaying ? "pause.fill" : "play.fill") { document.togglePlayback() }
            .help(document.isPlaying ? String(localized: "Pause (Space)") : String(localized: "Play (Space)"))
        SwiftUI.TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            Text("\(formatDuration(document.currentTime)) / \(formatDuration(duration))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
                .padding(.trailing, 12)
        }
    }
}

/// Horizontal bar between the panels above and the track list; dragging it trades height between
/// the timeline and the list. Its grip grows and lights up under the pointer.
private struct PaneSplitter: View {
    typealias Heights = (list: CGFloat, timeline: CGFloat)

    /// Called while dragging with the heights at the start of the drag and how far the bar moved down.
    let resize: (Heights, CGFloat) -> Void
    let heights: () -> Heights
    @State private var start: Heights?
    @State private var isHovered = false

    var body: some View {
        let active = isHovered || start != nil
        ZStack {
            Rectangle().fill(active ? Color.white.opacity(0.2) : Theme.hairline).frame(height: 1)
            Capsule().fill(Color.white.opacity(active ? 0.85 : 0.35))
                .frame(width: active ? 72 : 44, height: active ? 6 : 4)
                .overlay {
                    HStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { _ in Circle().fill(Theme.window.opacity(0.7)).frame(width: 2, height: 2) }
                    }
                    .opacity(active ? 1 : 0)
                }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 11)
        .background(Theme.window)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.15), value: active)
        .onHover { isHovered = $0 }
        .pointerStyle(.rowResize)
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    let start = start ?? heights()
                    self.start = start
                    resize(start, drag.translation.height)
                }
                .onEnded { _ in start = nil }
        )
        .help(String(localized: "Drag to resize the track list"))
    }
}

/// A key that acts anywhere in the window except while text is being edited; holding it acts once.
/// A local monitor sees the key before the focused list or button, which would otherwise take it.
private struct KeyMonitor: NSViewRepresentable {
    static let space: UInt16 = 49
    static let delete: UInt16 = 51

    let keyCode: UInt16
    /// Exactly the modifiers that must be held.
    let modifiers: NSEvent.ModifierFlags
    let action: @MainActor () -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.keyCode = keyCode
        view.modifiers = modifiers
        view.action = action
    }

    final class MonitorView: NSView {
        var keyCode: UInt16 = 0
        var modifiers: NSEvent.ModifierFlags = []
        var action: @MainActor () -> Void = {}
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return handled ? nil : event
            }
        }

        /// Whether the event was this key for this window, and so consumed.
        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, event.keyCode == keyCode,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]) == modifiers,
                  !(window.firstResponder is NSText) else { return false }
            if !event.isARepeat { action() }
            return true
        }
    }
}
