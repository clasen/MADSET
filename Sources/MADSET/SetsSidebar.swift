import AppKit
import MADSETCore
import SwiftUI

/// The sets in the library folder, grouped by the folders they are in. Clicking a set opens it.
/// Sets and groups drag onto a group, onto a set to join its group, or onto the header to leave
/// every group; the context menu makes, renames and reveals them.
struct SetsSidebar: View {
    /// The set in this window, highlighted in the list.
    let current: URL?
    @State private var library = SetLibraryModel.shared
    @State private var renaming: SetLibrary.Item?
    @State private var newName = ""
    @State private var isHeaderTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let folder = library.folder {
                List(selection: openingSelection) {
                    ForEach(library.items) { SetLibraryRow(item: $0, library: library) }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: URL.self) { urls in menu(for: urls, folder: folder) }
                .overlay {
                    if library.items.isEmpty {
                        Text("Sets saved in this folder show up here. Its folders become groups.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding()
                            .allowsHitTesting(false)
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("No Sets Folder", systemImage: "folder")
                } description: {
                    Text("Choose the folder that holds your sets. Its folders become groups.")
                } actions: {
                    Button("Choose Folder…") { library.chooseFolder() }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .background(Theme.panel)
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let renaming { library.rename(renaming.url, to: newName) } }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        }
        .alert("The sets folder could not be changed", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("OK") {}
        } message: {
            Text(library.error ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Sets").font(.system(size: 13, weight: .semibold))
            Spacer()
            if let folder = library.folder {
                Button("New Group", systemImage: "folder.badge.plus") { startRenaming(library.createGroup(in: folder)) }
                    .help(String(localized: "Make a group for sets"))
                Menu("More", systemImage: "ellipsis") {
                    Button("New Set") { library.createSet(in: folder) }
                    Divider()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    Button("Change Folder…") { library.chooseFolder() }
                }
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(isHeaderTargeted ? Theme.controlHover : Theme.panel)
        .dropDestination(for: URL.self) { urls, _ in
            guard let folder = library.folder else { return false }
            return library.move(urls, into: folder)
        } isTargeted: { isHeaderTargeted = $0 }
        .help(String(localized: "Drop a set or group here to take it out of its group"))
    }

    /// Highlights this window's set; picking another set opens it.
    private var openingSelection: Binding<URL?> {
        Binding(get: { current?.standardizedFileURL }, set: { url in
            guard let url, url.pathExtension.lowercased() == SetLibrary.fileExtension, url != current?.standardizedFileURL else { return }
            library.open(url)
        })
    }

    @ViewBuilder private func menu(for urls: Set<URL>, folder: URL) -> some View {
        let item = urls.count == 1 ? urls.first.flatMap(find) : nil
        // New items go inside a clicked group, next to a clicked set, or at the top level.
        let group = item.map { $0.isGroup ? $0.url : $0.url.deletingLastPathComponent() } ?? folder
        Button("New Set") { library.createSet(in: group) }
        Button("New Group") { startRenaming(library.createGroup(in: group)) }
        if let item {
            Divider()
            Button("Rename…") { startRenaming(item) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        }
    }

    private func find(_ url: URL) -> SetLibrary.Item? {
        func search(_ items: [SetLibrary.Item]) -> SetLibrary.Item? {
            for item in items {
                if item.url == url { return item }
                if let found = search(item.children ?? []) { return found }
            }
            return nil
        }
        return search(library.items)
    }

    private func startRenaming(_ item: SetLibrary.Item?) {
        guard let item else { return }
        newName = item.name
        renaming = item
    }
}

/// A set, or a group that folds open to show what is inside it.
private struct SetLibraryRow: View {
    let item: SetLibrary.Item
    let library: SetLibraryModel
    @State private var isExpanded = true
    @State private var isTargeted = false

    var body: some View {
        if let children = item.children {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(children) { SetLibraryRow(item: $0, library: library) }
            } label: {
                label
            }
        } else {
            label
        }
    }

    private var label: some View {
        Label(item.name, systemImage: item.isGroup ? "folder" : "music.note.list")
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(isTargeted ? Theme.controlHover : .clear, in: RoundedRectangle(cornerRadius: 4))
            .tag(item.url)
            .draggable(item.url)
            .dropDestination(for: URL.self) { urls, _ in
                library.move(urls, into: item.isGroup ? item.url : item.url.deletingLastPathComponent())
            } isTargeted: { isTargeted = $0 }
    }
}
