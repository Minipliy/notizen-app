import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import PencilKit
import Vision

/// Erkennt Text in Handschrift, Fotos und PDF-Seiten (auf dem Gerät, ohne Internet).
enum TextRecognizer {
    /// Texterkennung in einem Bild; Zeilen von oben nach unten.
    static func recognize(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["de-DE", "en-US"]
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? [])
            .sorted { a, b in
                // Vision zählt y von unten; gleiche Zeile → von links nach rechts.
                abs(a.boundingBox.midY - b.boundingBox.midY) < 0.01
                    ? a.boundingBox.minX < b.boundingBox.minX
                    : a.boundingBox.midY > b.boundingBox.midY
            }
            .compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    /// Handschrift auf weißem Grund rendern und erkennen.
    static func recognize(drawing: PKDrawing) -> String {
        guard !drawing.strokes.isEmpty else { return "" }
        let bounds = drawing.bounds.insetBy(dx: -20, dy: -20)
        guard let cg = renderOnWhite(drawing, rect: bounds) else { return "" }
        return recognize(cg)
    }

    static func recognize(imageAt url: URL) -> String {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return "" }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2400,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return "" }
        return recognize(cg)
    }

    /// Text einer PDF-Seite: eingebetteter Text, bei Scans per Erkennung.
    static func recognize(pdfAt url: URL, page index: Int) -> String {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: index) else { return "" }
        let embedded = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if embedded.count > 20 { return embedded }
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0 else { return embedded }
        let scale = 2000 / max(box.width, box.height)
        let size = CGSize(width: box.width * scale, height: box.height * scale)
        #if canImport(UIKit)
        guard let cg = page.thumbnail(of: size, for: .mediaBox).cgImage else { return embedded }
        #else
        guard let cg = page.thumbnail(of: size, for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return embedded }
        #endif
        let found = recognize(cg)
        return found.isEmpty ? embedded : found
    }

    private static func renderOnWhite(_ drawing: PKDrawing, rect: CGRect) -> CGImage? {
        let scale: CGFloat = min(2, 2400 / max(rect.width, rect.height, 1))
        let width = Int(rect.width * scale), height = Int(rect.height * scale)
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        #if canImport(UIKit)
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: rect, scale: scale)
        }
        guard let ink = image?.cgImage else { return nil }
        #else
        var image: NSImage?
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            image = drawing.image(from: rect, scale: scale)
        }
        guard let ink = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        #endif
        ctx.draw(ink, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}

extension NoteBlock {
    /// Schlüssel für den Inhalt, aus dem Text erkannt wird – ändert er sich, wird neu erkannt.
    var recognitionSource: String? {
        switch kind {
        case .text:
            return nil
        case .file:
            guard let f = file, f.isAudio else { return nil }
            return "audio:\(f.blob)"
        case .canvas:
            if let bg = background {
                return "\(bg.kind.rawValue):\(bg.blob):\(bg.page ?? 0)"
            }
            let images = (images ?? []).map(\.blob).joined(separator: ",")
            guard hasInk || !images.isEmpty else { return nil }
            let inkKey = drawing.map { BlobStore.sha256(Data($0.utf8)).prefix(16) } ?? ""
            return "ink:\(inkKey):\(images)"
        }
    }

    var needsRecognition: Bool {
        guard let source = recognitionSource else { return false }
        return recognizedKey != source
    }
}

extension NotesStore {
    /// Erkennt im Hintergrund Text in Handschrift, Fotos und PDF-Seiten, damit die Suche ihn findet.
    /// Das Ergebnis wird mit der Notiz abgeglichen, andere Geräte müssen es nicht noch einmal erkennen.
    func runRecognition() async {
        let blobs = self.blobs
        var processed = 0
        for note in notes where !note.deleted && !note.trashed {
            for block in note.content where block.needsRecognition {
                guard processed < 30, let source = block.recognitionSource else { return }
                // Fehlende Anhänge erst nach dem Herunterladen erkennen.
                let refs = block.blobRefs
                if refs.contains(where: { !blobs.exists($0) }) { continue }
                processed += 1
                if let f = block.file, f.isAudio {
                    if let text = await SpeechTranscriber.transcribe(blobs.url(f.blob)) {
                        applyRecognition(note.id, block.id, source: source, text: text)
                    }
                    continue
                }
                let text = await Task.detached(priority: .utility) { () -> String in
                    if let bg = block.background {
                        let url = blobs.url(bg.blob)
                        return bg.kind == .pdf
                            ? TextRecognizer.recognize(pdfAt: url, page: bg.page ?? 0)
                            : TextRecognizer.recognize(imageAt: url)
                    }
                    var parts: [String] = []
                    if let d = InkTools.decode(block.drawing) { parts.append(TextRecognizer.recognize(drawing: d)) }
                    for img in block.images ?? [] {
                        parts.append(TextRecognizer.recognize(imageAt: blobs.url(img.blob)))
                    }
                    return parts.filter { !$0.isEmpty }.joined(separator: "\n")
                }.value
                // Nur übernehmen, wenn sich der Inhalt inzwischen nicht geändert hat.
                applyRecognition(note.id, block.id, source: source, text: text)
            }
        }
    }

    func scheduleRecognition() {
        recognitionTask?.cancel()
        recognitionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if Task.isCancelled { return }
            await self?.runRecognition()
        }
    }
}
