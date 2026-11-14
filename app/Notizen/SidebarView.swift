import SwiftUI

struct SidebarView: View {
    @Environment(NotesStore.self) private var store
    @State private var showSettings = false
    @State private var showNewFolder = false
    @State private var folderName = ""
    @State private var renaming: Folder?

    var body: some View {
        @Bindable var store = store
        List(selection: $store.sidebarSelection) {
            Section {
                Label("Alle Notizen", systemImage: "tray.full")
                    .badge(store.count(for: .all))
                    .tag(SidebarItem.all)
                    .dropDestination(for: String.self) { ids, _ in
                        ids.forEach { store.move($0, to: nil) }
                        return !ids.isEmpty
                    }
            }
            Section("Ordner") {
                ForEach(store.visibleFolders) { folder in
                    Label(folder.name, systemImage: "folder")
                        .badge(store.count(for: .folder(folder.id)))
                        .tag(SidebarItem.folder(folder.id))
                        // Notizen aus der Liste hierher ziehen, um sie zu verschieben.
                        .dropDestination(for: String.self) { ids, _ in
                            ids.forEach { store.move($0, to: folder.id) }
                            return !ids.isEmpty
                        }
                        .contextMenu {
                            Button("Umbenennen", systemImage: "pencil") {
                                folderName = folder.name
                                renaming = folder
                            }
                            Button("Ordner löschen", systemImage: "trash", role: .destructive) {
                                store.deleteFolder(folder.id)
                            }
                        }
                }
            }
            let tags = store.allTags
            if !tags.isEmpty {
                Section("Tags") {
                    ForEach(tags, id: \.name) { tag in
                        Label(tag.name, systemImage: "number")
                            .badge(tag.count)
                            .tag(SidebarItem.tag(tag.name))
                    }
                }
            }
            Section {
                Label("Zuletzt gelöscht", systemImage: "trash")
                    .badge(store.count(for: .trash))
                    .tag(SidebarItem.trash)
            }
        }
        .navigationTitle("Ordner")
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        #endif
        .safeAreaInset(edge: .bottom) {
            SyncStatusView { showSettings = true }
        }
        .toolbar {
            ToolbarItem {
                Button("Neuer Ordner", systemImage: "folder.badge.plus") {
                    folderName = ""
                    showNewFolder = true
                }
            }
            ToolbarItem {
                Button("Einstellungen", systemImage: "gearshape") { showSettings = true }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .alert("Neuer Ordner", isPresented: $showNewFolder) {
            TextField("Name", text: $folderName)
            Button("Abbrechen", role: .cancel) {}
            Button("Sichern") { store.addFolder(named: folderName) }
        }
        .alert(
            "Ordner umbenennen",
            isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
        ) {
            TextField("Name", text: $folderName)
            Button("Abbrechen", role: .cancel) {}
            Button("Sichern") {
                if let renaming { store.renameFolder(renaming.id, to: folderName) }
            }
        }
    }
}

/// Kleine Statuszeile unten in der Seitenleiste: zeigt, ob der Pi erreichbar ist.
struct SyncStatusView: View {
    @Environment(NotesStore.self) private var store
    var openSettings: () -> Void

    var body: some View {
        Button(action: openSettings) {
            HStack(spacing: 6) {
                switch store.syncState {
                case .notConfigured:
                    Image(systemName: "icloud.slash")
                    Text("Server einrichten")
                case .syncing:
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Abgleich läuft …")
                case .idle:
                    Image(systemName: "checkmark.circle")
                    Text("Synchronisiert")
                case .error(let message):
                    Image(systemName: "exclamationmark.triangle")
                    Text(message)
                }
                Spacer(minLength: 0)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.bar)
    }
}
