import PencilKit
import SwiftUI

struct NoteListView: View {
    @Environment(NotesStore.self) private var store
    @State private var search = ""
    @AppStorage("noteSort") private var sort: NoteSort = .modified

    private var item: SidebarItem { store.sidebarSelection ?? .all }

    private var title: String {
        switch item {
        case .all: return "Alle Notizen"
        case .trash: return "Zuletzt gelöscht"
        case .folder(let id): return store.folders.first { $0.id == id }?.name ?? "Notizen"
        case .tag(let tag): return "#\(tag)"
        }
    }

    var body: some View {
        @Bindable var store = store
        let notes = store.notes(for: item, search: search, sort: sort)
        let pinned = item == .trash ? [] : notes.filter(\.pinned)
        let others = item == .trash ? notes : notes.filter { !$0.pinned }

        List(selection: $store.selectedNoteID) {
            if !pinned.isEmpty {
                Section("Angepinnt") {
                    ForEach(pinned) { row($0) }
                }
            }
            // Wie in Apple Notizen: nach Datum gruppiert.
            ForEach(sort == .title ? [NoteGroup(title: "Notizen", notes: others)]
                    : Self.groups(others, byCreation: sort == .created), id: \.title) { group in
                Section(group.title) {
                    ForEach(group.notes) { row($0) }
                }
            }
        }
        .navigationTitle(title)
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        #endif
        .searchable(text: $search, prompt: "Suchen")
        .overlay {
            if notes.isEmpty {
                if !search.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else if item == .trash {
                    ContentUnavailableView(
                        "Papierkorb ist leer", systemImage: "trash",
                        description: Text("Gelöschte Notizen bleiben hier 30 Tage."))
                } else {
                    ContentUnavailableView(
                        "Keine Notizen", systemImage: "note.text",
                        description: Text("Tippe auf das Stift-Symbol, um eine Notiz anzulegen."))
                }
            }
        }
        .toolbar {
            if item == .trash {
                ToolbarItem(placement: .primaryAction) {
                    Button("Papierkorb leeren", systemImage: "trash.slash", role: .destructive) {
                        store.emptyTrash()
                    }
                    .disabled(notes.isEmpty)
                }
            } else {
                ToolbarItem {
                    Menu {
                        Picker("Sortieren nach", selection: $sort) {
                            ForEach(NoteSort.allCases) { Text($0.label).tag($0) }
                        }
                    } label: {
                        Label("Sortieren", systemImage: "arrow.up.arrow.down")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Neue Notiz", systemImage: "square.and.pencil") {
                        search = ""
                        store.newNote()
                    }
                }
            }
        }
    }

    struct NoteGroup {
        let title: String
        var notes: [Note]
    }

    /// Heute, Gestern, Vorherige 7 Tage, Vorherige 30 Tage, danach nach Monaten bzw. Jahren.
    static func groups(_ notes: [Note], byCreation: Bool = false, now: Date = Date()) -> [NoteGroup] {
        let cal = Calendar.current
        let startToday = cal.startOfDay(for: now)
        var result: [NoteGroup] = []
        for note in notes {
            let date = byCreation ? note.createdDate : note.modifiedDate
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: startToday).day ?? 0
            let title: String
            switch days {
            case ..<1: title = "Heute"
            case 1: title = "Gestern"
            case 2...7: title = "Vorherige 7 Tage"
            case 8...30: title = "Vorherige 30 Tage"
            default:
                title = cal.isDate(date, equalTo: now, toGranularity: .year)
                    ? date.formatted(.dateTime.month(.wide))
                    : (now.timeIntervalSince(date) > 365 * 86400
                        ? date.formatted(.dateTime.year())
                        : date.formatted(.dateTime.month(.wide).year()))
            }
            if result.last?.title == title {
                result[result.count - 1].notes.append(note)
            } else {
                result.append(NoteGroup(title: title, notes: [note]))
            }
        }
        return result
    }

    @ViewBuilder
    private func row(_ note: Note) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(note.title)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(dateText(sort == .created ? note.createdDate : note.modifiedDate))
                    Text(note.preview)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            if note.isLocked {
                Image(systemName: store.unlocked[note.id] == nil ? "lock.fill" : "lock.open")
                    .foregroundStyle(.secondary)
            } else {
                NoteThumbnail(note: note)
            }
        }
        .padding(.vertical, 2)
        .tag(note.id)
        .draggable(note.id)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if note.trashed {
                Button("Endgültig löschen", systemImage: "trash", role: .destructive) {
                    store.deletePermanently(note.id)
                }
            } else {
                Button("Löschen", systemImage: "trash", role: .destructive) {
                    store.trash(note.id)
                }
            }
        }
        .swipeActions(edge: .leading) {
            if note.trashed {
                Button("Wiederherstellen", systemImage: "arrow.uturn.backward") {
                    store.restore(note.id)
                }
                .tint(.blue)
            } else {
                Button(note.pinned ? "Lösen" : "Anpinnen", systemImage: note.pinned ? "pin.slash" : "pin") {
                    store.togglePin(note.id)
                }
                .tint(.notesAccent)
            }
        }
        .contextMenu {
            if note.trashed {
                Button("Wiederherstellen", systemImage: "arrow.uturn.backward") {
                    store.restore(note.id)
                }
                Button("Endgültig löschen", systemImage: "trash", role: .destructive) {
                    store.deletePermanently(note.id)
                }
            } else {
                Button(note.pinned ? "Lösen" : "Anpinnen", systemImage: note.pinned ? "pin.slash" : "pin") {
                    store.togglePin(note.id)
                }
                Menu("Bewegen", systemImage: "folder") {
                    Button("Kein Ordner") { store.move(note.id, to: nil) }
                    ForEach(store.visibleFolders) { folder in
                        Button(folder.name) { store.move(note.id, to: folder.id) }
                    }
                }
                Button("Löschen", systemImage: "trash", role: .destructive) {
                    store.trash(note.id)
                }
            }
        }
    }

    private func dateText(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if Calendar.current.isDateInYesterday(date) {
            return "Gestern"
        }
        if let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }
}

/// Kleines Vorschaubild in der Notizliste: erstes Foto, erste PDF-Seite oder Handschrift.
struct NoteThumbnail: View {
    let note: Note

    private static var inkCache: [String: PlatformImage] = [:]

    var body: some View {
        if let bg = note.content.first(where: { $0.background != nil })?.background {
            BackgroundImageView(background: bg)
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.secondary.opacity(0.2)))
        } else if let placed = note.content.lazy.compactMap({ $0.images?.first }).first {
            BackgroundImageView(background: Background(kind: .image, blob: placed.blob, aspect: placed.h / placed.w))
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        } else if let ink = inkImage {
            Image(platformImage: ink)
                .resizable()
                .scaledToFit()
                .padding(4)
                .frame(width: 46, height: 46)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.secondary.opacity(0.2)))
        }
    }

    /// Ausschnitt der Handschrift – nur, wenn die Notiz keinen getippten Text hat.
    private var inkImage: PlatformImage? {
        guard note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let block = note.content.first(where: { $0.isInk && $0.hasInk }),
              let s = block.drawing else { return nil }
        let key = "\(s.count)|\(s.suffix(32))"
        if let hit = Self.inkCache[key] { return hit }
        guard let drawing = InkTools.decode(s), !drawing.strokes.isEmpty else { return nil }
        let rect = drawing.bounds.insetBy(dx: -10, dy: -10)
        let scale = min(1, 200 / max(rect.width, rect.height, 1))
        var image: PlatformImage?
        #if canImport(UIKit)
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: rect, scale: scale * 2)
        }
        #else
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            image = drawing.image(from: rect, scale: scale * 2)
        }
        #endif
        if Self.inkCache.count > 200 { Self.inkCache.removeAll() }
        if let image { Self.inkCache[key] = image }
        return image
    }
}
