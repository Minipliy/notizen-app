import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Angehängte Datei: antippen öffnet die Vorschau, teilen über das Menü.
struct FileBlockView: View {
    let file: FileRef
    @Environment(NotesStore.self) private var store
    @State private var previewURL: URL?

    private var icon: String {
        guard let t = file.type.flatMap(UTType.init) else { return "doc" }
        if t.conforms(to: .pdf) { return "doc.richtext" }
        if t.conforms(to: .image) { return "photo" }
        if t.conforms(to: .audio) { return "waveform" }
        if t.conforms(to: .movie) { return "film" }
        if t.conforms(to: .presentation) { return "rectangle.on.rectangle" }
        if t.conforms(to: .spreadsheet) { return "tablecells" }
        if t.conforms(to: .archive) { return "doc.zipper" }
        return "doc"
    }

    var body: some View {
        let available = store.blobs.exists(file.blob) || store.blobRevision < 0
        Button {
            previewURL = store.blobs.namedCopy(file.blob, name: file.name)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(Color.notesAccent)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name).font(.headline).lineLimit(1)
                    Text(available
                         ? ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)
                         : "Wird geladen …")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if available, let url = store.blobs.namedCopy(file.blob, name: file.name) {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(12)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .quickLookPreview($previewURL)
    }
}
