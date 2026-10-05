import AppKit
import MADSETCore
import SwiftUI

/// One window showing one set at a time; the sets sidebar switches between them.
@main
struct MADSETApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var library = SetLibraryModel.shared

    var body: some Scene {
        Window("MADSET", id: "main") {
            if let document = library.current {
                ContentView(document: document)
                    .navigationTitle(document.fileURL.deletingPathExtension().lastPathComponent)
                    .preferredColorScheme(.dark)
            }
        }
        .defaultSize(width: 1500, height: 880)
        .commands { SetCommands(library: library) }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Sets opened from the Finder show in the window.
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.last { SetLibraryModel.shared.show(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        SetLibraryModel.shared.current?.close()
    }
}

private struct SetCommands: Commands {
    let library: SetLibraryModel
    @FocusedValue(\.setDocument) private var document

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Set") { library.createSet(in: library.folder) }
                .keyboardShortcut("n")
            Button("Open Set…") { library.showChosenSet() }
                .keyboardShortcut("o")
            Divider()
            Button("Import Tracks…") { document?.importItems(ImportPanel.choose()) }
                .keyboardShortcut("i")
                .disabled(document == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { document?.saveNow() }
                .keyboardShortcut("s")
                .disabled(document == nil)
        }
        CommandGroup(replacing: .importExport) {
            Button("Export Mix as WAV…") { document?.exportMix(as: .wav) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(document?.canExport != true)
            Button("Export Mix as AAC…") { document?.exportMix(as: .aac) }
                .disabled(document?.canExport != true)
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
