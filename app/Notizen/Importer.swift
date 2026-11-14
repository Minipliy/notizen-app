import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import VisionKit
#endif

/// Wandelt Bilder, PDFs und Dateien in Blöcke um (läuft im Hintergrund).
enum Importer {
    /// Speichert ein Bild als Anhang; gibt Hash und Seitenverhältnis (Höhe/Breite) zurück.
    static func storeImage(_ image: PlatformImage, blobs: BlobStore) -> (blob: String, aspect: Double)? {
        guard let jpeg = image.jpegBlob(), let sha = try? blobs.put(jpeg) else { return nil }
        let px = image.pixelSize
        guard px.width > 0 else { return nil }
        return (sha, Double(px.height / px.width))
    }

    /// Foto/Bild → Zeichenfläche mit dem Bild als Hintergrund.
    static func imageBlock(_ data: Data, blobs: BlobStore) -> NoteBlock? {
        guard let image = PlatformImage(data: data) else { return nil }
        return imageBlock(image, blobs: blobs)
    }

    static func imageBlock(_ image: PlatformImage, blobs: BlobStore) -> NoteBlock? {
        guard let stored = storeImage(image, blobs: blobs) else { return nil }
        return imageBlock(blob: stored.blob, aspect: stored.aspect)
    }

    static func imageBlock(blob: String, aspect: Double) -> NoteBlock {
        var block = NoteBlock(kind: .canvas, background: Background(kind: .image, blob: blob, aspect: aspect))
        // Hochkant-Bilder kleiner anzeigen, damit sie nicht den ganzen Bildschirm füllen.
        block.scale = aspect > 1.1 ? 0.5 : 0.75
        return block
    }

    /// PDF → Dateiblock (Original) und je Seite eine Zeichenfläche zum Beschriften.
    static func pdfBlocks(_ data: Data, name: String, blobs: BlobStore) -> [NoteBlock] {
        guard let sha = try? blobs.put(data) else { return [] }
        let aspects = BackgroundCache.pdfPageAspects(data)
        var out = [NoteBlock(kind: .file, file: FileRef(blob: sha, name: name, size: data.count, type: UTType.pdf.identifier))]
        for (i, aspect) in aspects.enumerated() {
            out.append(NoteBlock(kind: .canvas, background: Background(kind: .pdf, blob: sha, page: i, aspect: aspect)))
        }
        return out
    }

    /// Beliebige Datei aus „Dateien“ / dem Finder.
    static func fileBlocks(_ url: URL, blobs: BlobStore) -> [NoteBlock] {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return [] }
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        let name = url.lastPathComponent
        if type.conforms(to: .pdf) {
            return pdfBlocks(data, name: name, blobs: blobs)
        }
        if type.conforms(to: .image), let block = imageBlock(data, blobs: blobs) {
            return [block]
        }
        guard let sha = try? blobs.put(data) else { return [] }
        return [NoteBlock(kind: .file, file: FileRef(blob: sha, name: name, size: data.count, type: type.identifier))]
    }
}

extension NotesStore {
    /// Fügt Blöcke nach `afterBlock` (oder am Ende) ein.
    func insert(_ newBlocks: [NoteBlock], into noteID: String, after afterBlock: String? = nil) {
        guard !newBlocks.isEmpty else { return }
        updateBlocks(noteID) { blocks in
            // Leeren Textblock am Ende nicht stehen lassen, wenn danach etwas eingefügt wird.
            if afterBlock == nil, let last = blocks.last, last.kind == .text, last.isEmpty {
                blocks.removeLast()
            }
            var index = blocks.endIndex
            if let afterBlock, let i = blocks.firstIndex(where: { $0.id == afterBlock }) {
                index = blocks.index(after: i)
            }
            blocks.insert(contentsOf: newBlocks, at: index)
        }
    }

    func moveBlock(_ noteID: String, _ blockID: String, by offset: Int) {
        updateBlocks(noteID) { blocks in
            guard let i = blocks.firstIndex(where: { $0.id == blockID }) else { return }
            let j = i + offset
            guard blocks.indices.contains(j) else { return }
            blocks.swapAt(i, j)
        }
    }

    func deleteBlock(_ noteID: String, _ blockID: String) {
        updateBlocks(noteID) { blocks in
            blocks.removeAll { $0.id == blockID }
            if blocks.isEmpty { blocks = [.text()] }
        }
    }

    /// Entfernt ein PDF samt allen seinen Seiten aus der Notiz.
    func removePDF(_ noteID: String, blob: String) {
        updateBlocks(noteID) { blocks in
            blocks.removeAll { $0.file?.blob == blob || ($0.background?.kind == .pdf && $0.background?.blob == blob) }
            if blocks.isEmpty { blocks = [.text()] }
        }
    }
}

#if os(iOS)
/// Dokumentenscanner von Apple (Kamera, automatische Kanten- und Perspektivkorrektur).
struct DocumentScanner: UIViewControllerRepresentable {
    var onFinish: ([UIImage]) -> Void

    static var isAvailable: Bool { VNDocumentCameraViewController.isSupported }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: ([UIImage]) -> Void
        init(onFinish: @escaping ([UIImage]) -> Void) { self.onFinish = onFinish }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            onFinish((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onFinish([])
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: Error) {
            onFinish([])
        }
    }
}
#endif

#if os(iOS)
/// Kamera zum direkten Aufnehmen eines Fotos.
struct CameraPicker: UIViewControllerRepresentable {
    var onFinish: (UIImage?) -> Void

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let vc = UIImagePickerController()
        vc.sourceType = .camera
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (UIImage?) -> Void
        init(onFinish: @escaping (UIImage?) -> Void) { self.onFinish = onFinish }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onFinish(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
        }
    }
}
#endif
