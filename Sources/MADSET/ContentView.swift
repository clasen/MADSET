import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(SetStore.self) private var store
    @State private var isDropTargeted = false
    @State private var fitRequest = 0

    var body: some View {
        HSplitView {
            TrackListView()
                .frame(minWidth: 340, idealWidth: 420, maxWidth: 600)
            TimelineView(
                clips: TimelineClip.layout(store.tracks),
                selection: store.selection,
                fitRequest: fitRequest,
                onSelect: { store.selection = $0 },
                onMove: { store.move($0, before: $1) }
            )
            .frame(minWidth: 500)
        }
        .overlay {
            if store.tracks.isEmpty {
                ContentUnavailableView("Arrastrá temas o carpetas", systemImage: "square.and.arrow.down",
                                       description: Text("MP3, AIFF, WAV, FLAC o M4A. Se analizan BPM, beatgrid, kick, fases y key."))
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3).padding(4).allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            store.importItems(urls)
            return !urls.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .toolbar {
            ToolbarItemGroup {
                Button("Importar", systemImage: "plus") { store.importItems(ImportPanel.choose()) }
                    .help("Agregar temas o carpetas al final del set (⌘O)")
                Button("Ajustar", systemImage: "arrow.left.and.right.square") { fitRequest += 1 }
                    .help("Ver el set completo")
            }
            ToolbarItem(placement: .status) {
                Text(summary).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .navigationTitle("MADSET")
    }

    private var summary: String {
        guard !store.tracks.isEmpty else { return "Set vacío" }
        var parts = ["\(store.tracks.count) temas", formatDuration(store.totalDuration)]
        if store.pendingCount > 0 { parts.append("analizando \(store.pendingCount)…") }
        return parts.joined(separator: " · ")
    }
}

enum ImportPanel {
    @MainActor
    static func choose() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio]
        panel.prompt = "Agregar al set"
        return panel.runModal() == .OK ? panel.urls : []
    }
}
