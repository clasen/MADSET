import AppKit
import BlendlineCore
import SwiftUI

/// The sets in the library folder as playlists, grouped by the folders they are in, with the loaded
/// set on top while it isn't among them. Clicking a set shows it in the track list; double-clicking
/// loads it into the timeline and decks, and a speaker marks the loaded one. Sets and groups drag
/// onto a group, onto a set to join its group, or onto the header to leave every group; tracks drag
/// onto a set to add them to it. Deleting a group keeps its sets; deleting a set moves it to the Trash.
struct SetsSidebar: View {
    var isFocused: FocusState<Bool>.Binding
    @State private var library = SetLibraryModel.shared
    @State private var renaming: SetLibrary.Item?
    @State private var newName = ""
    @State private var isHeaderTargeted = false
    @State private var trashing: [SetLibrary.Item] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
        }
        .background(Theme.panel)
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let renaming { library.rename(renaming.url, to: newName) } }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(trashTitle, isPresented: Binding(get: { !trashing.isEmpty }, set: { if !$0 { trashing = [] } })) {
            Button("Move to Trash", role: .destructive) { library.trash(trashing.map(\.url)) }
        }
        .alert("The sets folder could not be changed", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("OK") {}
        } message: {
            Text(library.error ?? "")
        }
    }

    private var list: some View {
        List(selection: browsingSelection) {
            if let loaded = library.loaded, !library.contains(loaded.fileURL) {
                SetLabel(name: loaded.fileURL.deletingPathExtension().lastPathComponent, isGroup: false, isLoaded: true)
                    .italic()
                    .tag(SetLibraryModel.loadedSet)
                    .draggable(SetLibraryModel.loadedSet)
            }
            ForEach(library.items) { SetLibraryRow(item: $0, library: library) }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: URL.self) { urls in
            menu(for: urls)
        } primaryAction: { urls in
            if let url = urls.first, urls.count == 1 { load(url) }
        }
        .focused(isFocused)
        .background {
            if isFocused.wrappedValue {
                KeyMonitor(keyCode: KeyMonitor.delete, modifiers: .command) {
                    delete(browsingSelection.wrappedValue.flatMap(find).map { [$0] } ?? [])
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Sets").font(.system(size: 13, weight: .semibold))
            Spacer()
            Button("New Group", systemImage: "folder.badge.plus") { startRenaming(library.createGroup(in: library.folder)) }
                .help(String(localized: "New Group"))
            Button("New Set", systemImage: "plus") { library.createSet(in: library.folder) }
                .help(String(localized: "New Set"))
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(isHeaderTargeted ? Theme.controlHover : Theme.panel)
        .dropDestination(for: URL.self) { urls, _ in
            library.drop(urls, onto: nil)
        } isTargeted: { isHeaderTargeted = $0 }
    }

    private var trashTitle: String {
        trashing.count == 1 ? String(localized: "Move the set “\(trashing[0].name)” to the Trash?")
            : String(localized: "Move \(trashing.count) sets to the Trash?")
    }

    /// Highlights the browsed set; picking another set browses it.
    private var browsingSelection: Binding<URL?> {
        Binding(get: {
            guard let browsed = library.browsed else { return nil }
            return library.contains(browsed.fileURL) ? browsed.fileURL.standardizedFileURL : SetLibraryModel.loadedSet
        }, set: { url in
            guard let url else { return }
            if url == SetLibraryModel.loadedSet, let loaded = library.loaded {
                library.browse(loaded.fileURL)
            } else if url.pathExtension.lowercased() == SetLibrary.fileExtension {
                library.browse(url)
            }
        })
    }

    private func load(_ url: URL) {
        if url == SetLibraryModel.loadedSet { return }
        if url.pathExtension.lowercased() == SetLibrary.fileExtension { library.load(url) }
    }

    @ViewBuilder private func menu(for urls: Set<URL>) -> some View {
        let items = urls.compactMap(find)
        let item = items.count == 1 ? items.first : nil
        // New items go inside a clicked group, next to a clicked set, or at the top level.
        let group = item.map { $0.isGroup ? $0.url : $0.url.deletingLastPathComponent() } ?? library.folder
        if let item, !item.isGroup {
            Button("Load") { library.load(item.url) }
            Divider()
        }
        Button("New Set") { library.createSet(in: group) }
        Button("New Group") { startRenaming(library.createGroup(in: group)) }
        if let item {
            Divider()
            Button("Rename…") { startRenaming(item) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        }
        if !items.isEmpty {
            Divider()
            Button("Delete") { delete(items) }
                .keyboardShortcut(.delete, modifiers: .command)
        }
    }

    /// Groups go at once and keep their sets; sets go to the Trash once confirmed.
    private func delete(_ items: [SetLibrary.Item]) {
        library.ungroup(items.filter(\.isGroup).map(\.url))
        trashing = items.filter { !$0.isGroup }
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
        SetLabel(name: item.name, isGroup: item.isGroup,
                 isLoaded: library.loaded.map { $0.fileURL.standardizedFileURL == item.url.standardizedFileURL } ?? false)
            .contentShape(Rectangle())
            .background(isTargeted ? Theme.controlHover : .clear, in: RoundedRectangle(cornerRadius: 4))
            .tag(item.url)
            .draggable(item.url)
            .dropDestination(for: URL.self) { urls, _ in
                library.drop(urls, onto: item)
            } isTargeted: { isTargeted = $0 }
    }
}

private struct SetLabel: View {
    let name: String
    let isGroup: Bool
    /// In the timeline and decks.
    let isLoaded: Bool

    var body: some View {
        HStack(spacing: 4) {
            Label(name, systemImage: isGroup ? "folder" : "music.note.list")
                .lineLimit(1)
            Spacer(minLength: 0)
            if isLoaded {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.accent)
            }
        }
    }
}
