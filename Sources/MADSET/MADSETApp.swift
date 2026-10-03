import MADSETCore
import SwiftUI

@main
struct MADSETApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { SetDocument() }) { file in
            ContentView(document: file.document)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1500, height: 880)
        .commands { SetCommands() }
    }
}

private struct SetCommands: Commands {
    @FocusedValue(\.setDocument) private var document

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Import Tracks…") { document?.importItems(ImportPanel.choose()) }
                .keyboardShortcut("i")
                .disabled(document == nil)
        }
        CommandMenu("Playback") {
            Button(document?.isPlaying == true ? LocalizedStringKey("Pause") : LocalizedStringKey("Play")) { document?.togglePlayback() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(document == nil)
            Button("Back to Start") { document?.seek(to: 0) }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                .disabled(document == nil)
        }
    }
}
