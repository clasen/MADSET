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
            if let document = library.loaded {
                ContentView(document: document, browsed: library.browsed ?? document) { library.load($0.fileURL) }
                    .navigationTitle(document.fileURL.deletingPathExtension().lastPathComponent)
                    .preferredColorScheme(.dark)
            }
        }
        .defaultSize(width: 1500, height: 880)
        .commands { SetCommands(library: library) }

        Settings {
            SettingsView()
                .preferredColorScheme(.dark)
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Sets opened from the Finder show in the window.
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.last { SetLibraryModel.shared.load(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        SetLibraryModel.shared.closeAll()
    }
}

/// The Order menu orders the selected tracks, or the whole set when fewer than two are selected.
private struct SetCommands: Commands {
    let library: SetLibraryModel
    @FocusedValue(\.setDocument) private var document
    @FocusedValue(\.browsedSet) private var browsed

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Set") { library.createSet(in: library.folder) }
                .keyboardShortcut("n")
            Button("Open Set…") { library.loadChosenSet() }
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
        CommandMenu("Order") {
            Button(SetOrder.Criterion.setCurve.title) { order(by: .setCurve) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(browsed == nil)
            Divider()
            ForEach([SetOrder.Criterion.energy, .energyDescending, .key, .bpm], id: \.self) { criterion in
                Button(criterion.title) { order(by: criterion) }
                    .disabled(browsed == nil)
            }
        }
        CommandMenu("Playback") {
            Button(document?.transportIsPlaying == true ? LocalizedStringKey("Pause") : LocalizedStringKey("Play")) { document?.togglePlayback() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(document == nil)
            Button("Back to Start") { document?.seek(to: 0) }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                .disabled(document == nil)
            Button("Forward a Phrase") { document.map { $0.move(byBars: $0.phraseBars) } }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(document == nil)
            Button("Back a Phrase") { document.map { $0.move(byBars: -$0.phraseBars) } }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(document == nil)
            Button("Forward a Bar") { document?.move(byBars: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [.option])
                .disabled(document == nil)
            Button("Back a Bar") { document?.move(byBars: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [.option])
                .disabled(document == nil)
            Button("Next Track") { document?.moveToTrack(forward: true) }
                .keyboardShortcut(.rightArrow, modifiers: [.shift])
                .disabled(document == nil)
            Button("Previous Track") { document?.moveToTrack(forward: false) }
                .keyboardShortcut(.leftArrow, modifiers: [.shift])
                .disabled(document == nil)
            Divider()
            Toggle("Monitor Mode", isOn: Binding { document?.monitorMode == true } set: { document?.setMonitorMode($0) })
                .keyboardShortcut("m", modifiers: [])
                .disabled(document == nil || !DeviceSettings.shared.hasMonitorOutput)
        }
    }

    private func order(by criterion: SetOrder.Criterion) {
        guard let document, let browsed else { return }
        let target = SetDocument.selectionTarget(loaded: document, browsed: browsed)
        target.order(target.selection, by: criterion)
    }
}
