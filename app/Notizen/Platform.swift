import SwiftUI

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
typealias PlatformColor = UIColor

extension Image {
    init(platformImage: PlatformImage) { self.init(uiImage: platformImage) }
}

extension PlatformImage {
    var pixelSize: CGSize { CGSize(width: size.width * scale, height: size.height * scale) }

    func jpegBlob(maxSide: CGFloat = 2400, quality: CGFloat = 0.85) -> Data? {
        let longest = max(size.width, size.height)
        let factor = min(1, maxSide / longest)
        let target = CGSize(width: (size.width * factor).rounded(), height: (size.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let img = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: target))
            draw(in: CGRect(origin: .zero, size: target))
        }
        return img.jpegData(compressionQuality: quality)
    }
}
#else
import AppKit
typealias PlatformImage = NSImage
typealias PlatformColor = NSColor

extension Image {
    init(platformImage: PlatformImage) { self.init(nsImage: platformImage) }
}

extension PlatformImage {
    var pixelSize: CGSize {
        if let rep = representations.first { return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh) }
        return size
    }

    func jpegBlob(maxSide: CGFloat = 2400, quality: CGFloat = 0.85) -> Data? {
        let px = pixelSize
        let longest = max(px.width, px.height)
        guard longest > 0 else { return nil }
        let factor = min(1, maxSide / longest)
        let target = NSSize(width: (px.width * factor).rounded(), height: (px.height * factor).rounded())
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: target).fill()
        draw(in: NSRect(origin: .zero, size: target))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
#endif
