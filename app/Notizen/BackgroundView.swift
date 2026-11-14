import ImageIO
import PDFKit
import SwiftUI

/// Rendert Bild- und PDF-Seiten-Hintergründe im Hintergrund und hält sie zwischengespeichert.
@MainActor
final class BackgroundCache {
    static let shared = BackgroundCache()
    private let cache = NSCache<NSString, PlatformImage>()

    init() { cache.countLimit = 60 }

    func image(for bg: Background, width: CGFloat, blobs: BlobStore) async -> PlatformImage? {
        // Breite in 300er-Schritten, damit beim Drehen nicht ständig neu gerendert wird.
        let w = max(300, (width / 300).rounded(.up) * 300)
        let key = "\(bg.blob)|\(bg.page ?? 0)|\(Int(w))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard blobs.exists(bg.blob) else { return nil }
        let url = blobs.url(bg.blob)
        let aspect = bg.aspect
        let image: PlatformImage? = await Task.detached(priority: .userInitiated) {
            switch bg.kind {
            case .image: return Self.downsample(url, maxPixel: w * 2 * max(1, aspect))
            case .pdf: return Self.renderPDF(url, page: bg.page ?? 0, width: w)
            }
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    nonisolated static func downsample(_ url: URL, maxPixel: CGFloat) -> PlatformImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        #if canImport(UIKit)
        return UIImage(cgImage: cg)
        #else
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #endif
    }

    nonisolated static func renderPDF(_ url: URL, page index: Int, width: CGFloat) -> PlatformImage? {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: index) else { return nil }
        let box = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let pageW = rotated ? box.height : box.width
        let pageH = rotated ? box.width : box.height
        guard pageW > 0 else { return nil }
        let scale = width / pageW * 2  // doppelte Auflösung für scharfe Darstellung
        return page.thumbnail(of: CGSize(width: pageW * scale, height: pageH * scale), for: .mediaBox)
    }

    /// Seitenverhältnisse (Höhe/Breite) aller Seiten eines PDFs.
    nonisolated static func pdfPageAspects(_ data: Data) -> [Double] {
        guard let doc = PDFDocument(data: data) else { return [] }
        return (0..<doc.pageCount).compactMap { i in
            guard let page = doc.page(at: i) else { return nil }
            let box = page.bounds(for: .mediaBox)
            let rotated = page.rotation % 180 != 0
            let w = rotated ? box.height : box.width
            let h = rotated ? box.width : box.height
            return w > 0 ? Double(h / w) : 1.414
        }
    }
}

/// Bild oder PDF-Seite als Hintergrund einer Zeichenfläche.
struct BackgroundImageView: View {
    let background: Background
    @Environment(NotesStore.self) private var store
    @State private var image: PlatformImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.white
                if let image {
                    Image(platformImage: image)
                        .resizable()
                        .interpolation(.high)
                } else if !store.blobs.exists(background.blob) {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Wird geladen …").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .task(id: "\(background.blob)|\(background.page ?? 0)|\(Int(geo.size.width))|\(store.blobRevision)") {
                guard geo.size.width > 0 else { return }
                image = await BackgroundCache.shared.image(
                    for: background, width: geo.size.width, blobs: store.blobs)
            }
        }
    }
}
