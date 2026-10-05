import AppKit
import MADSETCore
import SwiftUI

/// The sets in the library folder, grouped by the folders they are in, with this window's set on
/// top while it isn't among them. Clicking a set shows it in the window. Sets and groups drag onto a group, onto a
/// set to join its group, or onto the header to leave every group; dragging this window's set in
/// saves it there. Deleting a group keeps its sets; deleting a set moves it to the Trash.
struct SetsSidebar: View {
    @State private var library = SetLibraryModel.shared
    @State private var renaming: SetLibrary.Item?
    @State private var newName = ""
    @State private var isHeaderTargeted = false
    @State private var trashing: [SetLibrary.Item] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List(selection: openingSelection) {
                if !isCurrentInLibrary {
                    Label(current?.deletingPathExtension().lastPathComponent ?? "", systemImage: "music.note.list")
                        .italic()
                        .lineLimit(1)
                        .tag(SetLibraryModel.currentSet)
                        .draggable(SetLibraryModel.currentSet)
                }
                ForEach(library.items) { SetLibraryRow(item: $0, library: library) }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: URL.self) { urls in menu(for: urls) }
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

    private var current: URL? { library.current?.fileURL }
    private var isCurrentInLibrary: Bool { current.map(library.contains) ?? false }

    private var trashTitle: String {
        trashing.count == 1 ? String(localized: "Move the set “\(trashing[0].name)” to the Trash?")
            : String(localized: "Move \(trashing.count) sets to the Trash?")
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
            library.drop(urls, into: library.folder)
        } isTargeted: { isHeaderTargeted = $0 }
    }

    /// Highlights the set on show; picking another set shows it instead.
    private var openingSelection: Binding<URL?> {
        Binding(get: { isCurrentInLibrary ? current?.standardizedFileURL : SetLibraryModel.currentSet }, set: { url in
            guard let url, url.pathExtension.lowercased() == SetLibrary.fileExtension, url != current?.standardizedFileURL else { return }
            library.show(url)
        })
    }

    @ViewBuilder private func menu(for urls: Set<URL>) -> some View {
        let items = urls.compactMap(find)
        let item = items.count == 1 ? items.first : nil
        // New items go inside a clicked group, next to a clicked set, or at the top level.
        let group = item.map { $0.isGroup ? $0.url : $0.url.deletingLastPathComponent() } ?? library.folder
        Button("New Set") { library.createSet(in: group) }
        Button("New Group") { startRenaming(library.createGroup(in: group)) }
        if let item {
            Divider()
            Button("Rename…") { startRenaming(item) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        }
        if !items.isEmpty {
            Divider()
            Button("Delete") {
                library.ungroup(items.filter(\.isGroup).map(\.url))
                trashing = items.filter { !$0.isGroup }
            }
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
                library.drop(urls, into: item.isGroup ? item.url : item.url.deletingLastPathComponent())
            } isTargeted: { isTargeted = $0 }
    }
}
