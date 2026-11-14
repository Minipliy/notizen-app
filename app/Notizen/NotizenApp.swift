import SwiftUI

extension Color {
    /// Das Gelb-Orange von Apple Notizen.
    static let notesAccent = Color(red: 0.93, green: 0.67, blue: 0.05)
}

@main
struct NotizenApp: App {
    @State private var store = NotesStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .tint(.notesAccent)
                #if os(macOS) && DEBUG
                .task { await MacScreenshot.runIfRequested() }
                #endif
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await store.sync() }
                    } else {
                        store.saveNow()
                        if phase == .background { store.relockAll() }
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Neue Notiz") { store.newNote() }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}

#if os(macOS) && DEBUG
import AppKit

/// Nur für App-Store-Screenshots: Start mit  -shotSize 1280x800  bringt das Fenster auf genau diese Größe.
enum MacScreenshot {
    @MainActor
    static func runIfRequested() async {
        guard let size = UserDefaults.standard.string(forKey: "shotSize") else { return }
        let parts = size.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return }
        try? await Task.sleep(for: .seconds(1))
        guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return }
        window.setFrame(NSRect(x: 60, y: 60, width: parts[0], height: parts[1]), display: true)
    }
}
#endif

struct ContentView: View {
    @Environment(NotesStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView()
        } content: {
            NoteListView()
        } detail: {
            if let id = store.selectedNoteID, store.note(id) != nil {
                NoteEditorView(noteID: id)
                    .id(id)
            } else {
                ContentUnavailableView(
                    "Keine Notiz ausgewählt",
                    systemImage: "note.text",
                    description: Text("Wähle eine Notiz aus oder lege eine neue an."))
            }
        }
        .onChange(of: store.selectedNoteID) { old, _ in
            if let old {
                store.discardIfBlank(old)
                store.relock(old)
            }
        }
    }
}
