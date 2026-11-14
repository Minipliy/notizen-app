import PencilKit
import SwiftUI

/// Exportiert eine ganze Notiz als PDF (A4): Text mit Formeln, Handschrift, Fotos, PDF-Seiten.
@MainActor
enum NoteExporter {
    static let page = CGSize(width: 595, height: 842)
    static let margin: CGFloat = 42
    static var contentWidth: CGFloat { page.width - 2 * margin }
    static var contentHeight: CGFloat { page.height - 2 * margin }

    static func exportPDF(_ note: Note, blobs: BlobStore) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notiz-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = note.title.replacingOccurrences(of: "/", with: "-").prefix(60)
        let url = dir.appendingPathComponent("\(name.isEmpty ? "Notiz" : String(name)).pdf")
        var box = CGRect(origin: .zero, size: page)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return nil }

        var y: CGFloat = 0
        ctx.beginPDFPage(nil)
        func newPage() {
            ctx.endPDFPage()
            ctx.beginPDFPage(nil)
            y = 0
        }

        func place(_ view: some View, gap: CGFloat = 10, fitToPage: Bool = false) {
            let renderer = ImageRenderer(content: view
                .frame(width: contentWidth, alignment: .leading)
                .environment(\.colorScheme, .light))
            renderer.proposedSize = ProposedViewSize(width: contentWidth, height: nil)
            renderer.render { size, draw in
                guard size.height > 0 else { return }
                var scale: CGFloat = 1
                if fitToPage, size.height > contentHeight { scale = contentHeight / size.height }
                let h = size.height * scale
                if y + h > contentHeight, y > 0 { newPage() }
                ctx.saveGState()
                ctx.translateBy(x: margin + (contentWidth - size.width * scale) / 2,
                                y: page.height - margin - y - h)
                ctx.scaleBy(x: scale, y: scale)
                draw(ctx)
                ctx.restoreGState()
                y += h + gap
            }
        }

        place(Text(note.modifiedDate.formatted(date: .long, time: .shortened))
            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity), gap: 14)

        for block in note.content where !block.isOverlay {
            switch block.kind {
            case .text:
                // Absatzweise setzen, damit lange Texte sauber über Seiten laufen.
                for chunk in chunks(block.text ?? "") {
                    place(RichTextView(text: chunk).foregroundStyle(.black), gap: 4)
                }
                y += 6
            case .file:
                if let f = block.file {
                    place(Label(f.name, systemImage: "paperclip").font(.callout).foregroundStyle(.black))
                }
            case .canvas:
                if block.isEmpty { continue }
                if block.isInk {
                    // Lange Handschrift in Seitenstücke teilen.
                    let zoom = contentWidth / CGFloat(canvasWidth)
                    let total = CGFloat(max(block.contentBottom + 30, 60))
                    let sliceLogical = contentHeight / zoom
                    var top: CGFloat = 0
                    while top < total {
                        let height = min(sliceLogical, total - top)
                        if y + height * zoom > contentHeight, y > 0 { newPage() }
                        place(ExportCanvas(block: block, paper: "blank", blobs: blobs, top: top, height: height))
                        top += height
                    }
                } else {
                    place(ExportCanvas(block: block, paper: "blank", blobs: blobs, top: 0,
                                       height: CGFloat(block.canvasHeight))
                            .frame(width: contentWidth * CGFloat(block.displayScale))
                            .frame(maxWidth: .infinity),
                          gap: 14, fitToPage: true)
                }
            }
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    /// Teilt Text an Elementgrenzen (Absatz, Liste, Formel, Codeblock).
    static func chunks(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        let starts = RichTextView.parse(text).map(\.id) + [lines.count]
        var out: [String] = []
        for (a, b) in zip(starts, starts.dropFirst()) where a < b {
            out.append(lines[a..<min(b, lines.count)].joined(separator: "\n"))
        }
        return out.isEmpty ? [text] : out
    }
}

/// Zeichenfläche für den Export: Hintergrund, platzierte Bilder und Handschrift, synchron geladen.
struct ExportCanvas: View {
    let block: NoteBlock
    let paper: String
    let blobs: BlobStore
    /// Ausschnitt in logischen Punkten.
    let top: CGFloat
    let height: CGFloat

    var body: some View {
        GeometryReader { geo in
            let z = geo.size.width / CGFloat(canvasWidth)
            ZStack(alignment: .topLeading) {
                Color.white
                if let bg = block.background, let image = backgroundImage(bg) {
                    Image(platformImage: image).resizable()
                        .frame(width: geo.size.width, height: CGFloat(block.canvasHeight) * z)
                        .offset(y: -top * z)
                }
                ForEach(block.images ?? []) { img in
                    if let image = BackgroundCache.downsample(blobs.url(img.blob), maxPixel: 1600) {
                        Image(platformImage: image).resizable()
                            .frame(width: img.w * z, height: img.h * z)
                            .offset(x: img.x * z, y: (img.y - top) * z)
                    }
                }
                if let drawing = InkTools.decode(block.drawing),
                   let ink = InkImageView.render(drawing, height: Double(block.canvasHeight), light: true, scale: 2.5) {
                    Image(platformImage: ink).resizable()
                        .frame(width: geo.size.width, height: CGFloat(block.canvasHeight) * z)
                        .offset(y: -top * z)
                }
            }
            .frame(width: geo.size.width, height: height * z, alignment: .topLeading)
            .clipped()
        }
        .aspectRatio(CGFloat(canvasWidth) / max(height, 1), contentMode: .fit)
    }

    private func backgroundImage(_ bg: Background) -> PlatformImage? {
        guard blobs.exists(bg.blob) else { return nil }
        let url = blobs.url(bg.blob)
        return bg.kind == .pdf
            ? BackgroundCache.renderPDF(url, page: bg.page ?? 0, width: 900)
            : BackgroundCache.downsample(url, maxPixel: 2000)
    }
}
