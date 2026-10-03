import MADSETCore
import SwiftUI

@main
struct MADSETApp: App {
    @State private var store: SetStore

    init() {
        do {
            _store = State(initialValue: try SetStore(config: .current))
        } catch {
            fatalError("Could not open the analysis cache: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1500, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Importar…") { store.importItems(ImportPanel.choose()) }
                    .keyboardShortcut("o")
            }
        }
    }
}
