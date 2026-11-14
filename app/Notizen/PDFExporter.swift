import CoreGraphics
import Foundation
import PencilKit

/// Schreibt ein PDF samt handschriftlichen Anmerkungen in eine neue Datei.
@MainActor
enum PDFExporter {
    /// - Parameter ink: Zeichnung (Base64) je Seitennummer (ab 0).
    static func export(source: URL, name: String, ink: [Int: String]) -> URL? {
        guard let doc = CGPDFDocument(source as CFURL), doc.numberOfPages > 0 else { return nil }
        let base = (name as NSString).deletingPathExtension
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("\(base.isEmpty ? "Dokument" : base) (Anmerkungen).pdf")
        guard let ctx = CGContext(out as CFURL, mediaBox: nil, nil) else { return nil }

        for index in 0..<doc.numberOfPages {
            guard let page = doc.page(at: index + 1) else { continue }
            let box = page.getBoxRect(.mediaBox)
            let rotated = page.rotationAngle % 180 != 0
            let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
            var rect = CGRect(origin: .zero, size: size)
            ctx.beginPage(mediaBox: &rect)
            ctx.saveGState()
            ctx.concatenate(page.getDrawingTransform(.mediaBox, rect: rect, rotate: 0, preserveAspectRatio: true))
            ctx.drawPDFPage(page)
            ctx.restoreGState()

            if let drawing = InkTools.decode(ink[index]), !drawing.strokes.isEmpty, size.width > 0,
               let image = InkImageView.render(drawing, height: canvasWidth * Double(size.height / size.width),
                                               light: true, scale: 3),
               let cg = cgImage(image) {
                ctx.draw(cg, in: rect)
            }
            ctx.endPage()
        }
        ctx.closePDF()
        return out
    }

    private static func cgImage(_ image: PlatformImage) -> CGImage? {
        #if canImport(UIKit)
        return image.cgImage
        #else
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }
}
