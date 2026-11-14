import SwiftMath
import SwiftUI

/// Setzt LaTeX-Formeln mit SwiftMath und liefert sie als Bild (für Formeln mitten im Text)
/// oder als Ansicht (für abgesetzte Formeln).
@MainActor
enum MathRenderer {
    struct Rendered {
        let image: PlatformImage
        /// Abstand der Grundlinie vom unteren Bildrand.
        let descent: CGFloat
    }

    private static var cache: [String: Rendered] = [:]
    private static var failed: Set<String> = []

    static func render(_ latex: String, fontSize: CGFloat, dark: Bool, display: Bool = false,
                       maxWidth: CGFloat = 0) -> Rendered? {
        let key = "\(display ? "D" : "T")|\(Int(fontSize))|\(dark)|\(Int(maxWidth))|\(latex)"
        if let hit = cache[key] { return hit }
        if failed.contains(key) { return nil }

        let label = MTMathUILabel()
        label.displayErrorInline = false
        label.labelMode = display ? .display : .text
        label.font = MTFontManager().latinModernFont(withSize: fontSize)
        label.textColor = dark ? PlatformColor(white: 0.95, alpha: 1) : PlatformColor(white: 0.08, alpha: 1)
        label.latex = latex
        guard label.error == nil, label.mathList != nil else {
            failed.insert(key)
            return nil
        }
        var size = label.intrinsicContentSize
        size.width = ceil(max(size.width, 1))
        size.height = ceil(max(size.height, 1))
        label.frame = CGRect(origin: .zero, size: size)

        #if canImport(UIKit)
        label.backgroundColor = .clear
        label.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            // SwiftMath zeichnet mit y-Achse nach oben (wie Core Text).
            ctx.cgContext.translateBy(x: 0, y: size.height)
            ctx.cgContext.scaleBy(x: 1, y: -1)
            label.layer.render(in: ctx.cgContext)
        }
        #else
        // Auf dem Mac meldet die Ansicht keine eigene Größe: groß anlegen, setzen lassen,
        // Größe aus der gesetzten Formel nehmen und diese direkt zeichnen.
        let frameHeight: CGFloat = 1000
        label.textAlignment = .left
        label.contentInsets = MTEdgeInsets()
        label.frame = CGRect(x: 0, y: 0, width: 4000, height: frameHeight)
        label.layout()
        guard let list = label.displayList else { return nil }
        let h = list.ascent + list.descent
        size = CGSize(width: ceil(max(list.width, 1)), height: ceil(max(h, 1)))
        // Die Formel liegt senkrecht zentriert im großen Rahmen – entsprechend verschieben.
        let shift = (frameHeight - h) / 2
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.translateBy(x: 0, y: -shift)
            list.draw(ctx)
            return true
        }
        #endif

        let descent = label.displayList?.descent ?? 0
        let result = Rendered(image: image, descent: descent)
        if cache.count > 400 { cache.removeAll() }
        cache[key] = result
        return result
    }
}

/// Abgesetzte Formel (`$$ … $$`), zentriert.
struct DisplayMathView: View {
    let latex: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            content(width: geo.size.width)
        }
        .frame(height: height)
    }

    private var rendered: MathRenderer.Rendered? {
        MathRenderer.render(latex, fontSize: 21, dark: scheme == .dark, display: true)
    }

    private var height: CGFloat {
        guard let r = rendered else { return 24 }
        return r.image.size.height + 8
    }

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        if let r = rendered {
            let w = min(r.image.size.width, width)
            Image(platformImage: r.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: w)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        } else {
            Text("$$\(latex)$$")
                .font(.body.monospaced())
                .foregroundStyle(.red)
        }
    }
}
