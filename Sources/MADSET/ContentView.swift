import AppKit
import MADSETCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var document: SetDocument
    @Environment(\.undoManager) private var undoManager
    @State private var isDropTargeted = false
    @State private var fitRequest = 0

    var body: some View {
        let layout = document.layout
        HSplitView {
            TrackListView(document: document, setBPM: layout.bpm)
                .frame(minWidth: 340, idealWidth: 420, maxWidth: 600)
            VStack(spacing: 0) {
                TimelineView(document: document, clips: TimelineClip.clips(for: layout, tracks: document.tracks), fitRequest: fitRequest)
                    .overlay {
                        if document.tracks.isEmpty {
                            ContentUnavailableView("Drop tracks or folders here", systemImage: "square.and.arrow.down",
                                                   description: Text("MP3, AIFF, WAV, FLAC or M4A. Tempo, beatgrid, kick, phases and key are analyzed."))
                                .allowsHitTesting(false)
                        }
                    }
                TransportBar(document: document, layout: layout)
            }
            .frame(minWidth: 500)
        }
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
            ToolbarItemGroup {
                Button("Import", systemImage: "plus") { document.importItems(ImportPanel.choose()) }
                    .help(String(localized: "Add tracks or folders to the end of the set (⌘I)"))
                Button("Fit", systemImage: "arrow.left.and.right.square") { fitRequest += 1 }
                    .help(String(localized: "Show the whole set"))
            }
            ToolbarItem(placement: .status) {
                Text(summary(layout)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .alert("Playback is not available", isPresented: Binding(get: { document.playbackError != nil }, set: { if !$0 { document.clearPlaybackError() } })) {
            Button("OK") {}
        } message: {
            Text(document.playbackError ?? "")
        }
        .focusedSceneValue(\.setDocument, document)
        .onAppear {
            document.undoManager = undoManager
            document.start()
        }
        .onChange(of: undoManager) { document.undoManager = undoManager }
    }

    private func summary(_ layout: SetLayout) -> String {
        guard !document.tracks.isEmpty else { return String(localized: "Empty set") }
        var parts = [String(localized: "\(document.tracks.count) tracks"), formatDuration(layout.duration)]
        if document.pendingCount > 0 { parts.append(String(localized: "analyzing \(document.pendingCount)…")) }
        return parts.joined(separator: " · ")
    }
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
