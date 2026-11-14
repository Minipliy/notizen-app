import PencilKit
import SwiftUI

/// Zeichenfläche: Handschrift-Abschnitt (mit frei platzierten Bildern) oder
/// Fläche über einem Bild bzw. einer PDF-Seite.
struct CanvasBlockView: View {
    let noteID: String
    let block: NoteBlock
    /// Fingertipp auf freie Fläche (logische Koordinaten).
    var onTap: ((CGPoint) -> Void)? = nil
    /// Langes Drücken mit dem Finger (logische Koordinaten).
    var onLongPress: ((CGPoint) -> Void)? = nil
    /// Papier für Handschrift-Abschnitte: "blank", "lined" oder "grid".
    var paper: String = "blank"
    /// Auf dieser Fläche wird gerade geschrieben.
    var onActivate: (() -> Void)? = nil
    /// Bild per Cmd+V bzw. „Einsetzen“ auf dieser Fläche eingefügt.
    var onPasteImage: ((PlatformImage) -> Void)? = nil

    @Environment(NotesStore.self) private var store
    @State private var selectedImage: String?
    @State private var dragOffset: CGSize = .zero
    @State private var resizeDelta: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let bg = block.background {
                BackgroundImageView(background: bg)
            } else if paper != "blank" {
                PaperView(style: paper)
            }
            GeometryReader { geo in
                let z = geo.size.width / CGFloat(canvasWidth)
                ForEach(block.images ?? []) { img in
                    let r = liveRect(img, zoom: z)
                    BackgroundImageView(background: Background(kind: .image, blob: img.blob, aspect: img.h / img.w))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                }
            }
            #if os(iOS)
            CanvasRepresentable(noteID: noteID, block: block, onFingerTap: handleTap, onLongPress: onLongPress,
                                onActivate: onActivate, onPasteImage: onPasteImage)
            #else
            InkImageView(block: block)
            #endif
            if let img = (block.images ?? []).first(where: { $0.id == selectedImage }) {
                GeometryReader { geo in
                    selectionControls(img, zoom: geo.size.width / CGFloat(canvasWidth))
                }
            }
        }
        .aspectRatio(CGFloat(1 / block.canvasAspect), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: block.background == nil ? 0 : 10))
        .overlay {
            if block.background != nil {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25))
            }
        }
    }

    // MARK: - Platzierte Bilder

    private func liveRect(_ img: PlacedImage, zoom z: CGFloat) -> CGRect {
        var r = CGRect(x: img.x * z, y: img.y * z, width: img.w * z, height: img.h * z)
        if img.id == selectedImage {
            r.origin.x += dragOffset.width
            r.origin.y += dragOffset.height
            let w = max(60, r.width + resizeDelta)
            r.size = CGSize(width: w, height: w * img.h / img.w)
        }
        return r
    }

    private func handleTap(_ p: CGPoint) {
        if selectedImage != nil {
            selectedImage = nil
            return
        }
        if let hit = (block.images ?? []).last(where: { $0.rect.contains(p) }) {
            selectedImage = hit.id
            return
        }
        onTap?(p)
    }

    @ViewBuilder
    private func selectionControls(_ img: PlacedImage, zoom z: CGFloat) -> some View {
        let r = liveRect(img, zoom: z)
        // Verschieben
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color.notesAccent, lineWidth: 2)
            .contentShape(Rectangle())
            .frame(width: r.width, height: r.height)
            .offset(x: r.minX, y: r.minY)
            .gesture(
                DragGesture()
                    .onChanged { dragOffset = $0.translation }
                    .onEnded { g in
                        let dx = g.translation.width / z, dy = g.translation.height / z
                        dragOffset = .zero
                        update(img.id) {
                            $0.x = min(max(0, $0.x + dx), canvasWidth - $0.w)
                            $0.y = max(0, $0.y + dy)
                        }
                    })
        // Größe ändern
        Circle()
            .fill(Color.notesAccent)
            .overlay(Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption2.bold()).foregroundStyle(.white))
            .frame(width: 30, height: 30)
            .offset(x: r.maxX - 15, y: r.maxY - 15)
            .gesture(
                DragGesture()
                    .onChanged { resizeDelta = $0.translation.width }
                    .onEnded { g in
                        let dw = g.translation.width / z
                        resizeDelta = 0
                        update(img.id) {
                            let aspect = $0.h / $0.w
                            $0.w = min(max(60, $0.w + dw), canvasWidth - $0.x)
                            $0.h = $0.w * aspect
                        }
                    })
        // Entfernen
        Button {
            let id = img.id
            selectedImage = nil
            store.updateBlock(noteID, block.id) { b in
                b.images?.removeAll { $0.id == id }
                if b.images?.isEmpty == true { b.images = nil }
            }
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.red)
        }
        .buttonStyle(.plain)
        .offset(x: r.minX - 12, y: r.minY - 12)
    }

    private func update(_ imageID: String, _ change: (inout PlacedImage) -> Void) {
        store.updateBlock(noteID, block.id) { b in
            guard let i = b.images?.firstIndex(where: { $0.id == imageID }) else { return }
            change(&b.images![i])
        }
    }
}

/// Liniertes oder kariertes Papier. Die Linien hängen an der Fläche selbst,
/// damit Handschrift immer auf ihren Linien bleibt.
struct PaperView: View {
    let style: String

    static let lineSpacing: Double = 36
    static let gridSpacing: Double = 24

    var body: some View {
        Canvas { ctx, size in
            let z = size.width / CGFloat(canvasWidth)
            let grid = style == "grid"
            let step = CGFloat(grid ? Self.gridSpacing : Self.lineSpacing) * z
            guard step > 2 else { return }
            var path = Path()
            var y = step
            while y < size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }
            if grid {
                var x = step
                while x < size.width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    x += step
                }
            }
            ctx.stroke(path, with: .color(.secondary.opacity(grid ? 0.22 : 0.3)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

/// Zeichnung als Bild (auf dem Mac, wo es keine PencilKit-Zeichenfläche gibt).
struct InkImageView: View {
    let block: NoteBlock
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let image {
            Image(platformImage: image).resizable()
        }
    }

    private var image: PlatformImage? {
        guard let drawing = InkTools.decode(block.drawing), !drawing.strokes.isEmpty else { return nil }
        return InkImageView.render(drawing, height: block.canvasHeight,
                                   light: block.background != nil || scheme == .light, scale: 2)
    }

    /// Rendert eine Zeichnung der logischen Breite `canvasWidth` als Bild.
    static func render(_ drawing: PKDrawing, height: Double, light: Bool, scale: CGFloat) -> PlatformImage? {
        let rect = CGRect(x: 0, y: 0, width: canvasWidth, height: height)
        #if canImport(UIKit)
        var result: UIImage?
        UITraitCollection(userInterfaceStyle: light ? .light : .dark).performAsCurrent {
            result = drawing.image(from: rect, scale: scale)
        }
        return result
        #else
        var result: NSImage?
        NSAppearance(named: light ? .aqua : .darkAqua)?.performAsCurrentDrawingAppearance {
            result = drawing.image(from: rect, scale: scale)
        }
        return result
        #endif
    }
}

#if os(iOS)
/// Eine gemeinsame Werkzeugleiste (Stifte, Farben, Radierer, Lasso, Lineal) für alle Zeichenflächen.
@MainActor
final class ToolPickerCenter {
    static let shared = ToolPickerCenter()
    let picker = PKToolPicker()
    weak var activeCanvas: PKCanvasView?

    func activate(_ canvas: PKCanvasView) {
        picker.addObserver(canvas)
        picker.setVisible(true, forFirstResponder: canvas)
        canvas.becomeFirstResponder()
        activeCanvas = canvas
    }

    func hide() {
        if let c = activeCanvas {
            picker.setVisible(false, forFirstResponder: c)
            c.resignFirstResponder()
        }
    }
}

struct CanvasRepresentable: UIViewRepresentable {
    let noteID: String
    let block: NoteBlock
    var onFingerTap: ((CGPoint) -> Void)? = nil
    var onLongPress: ((CGPoint) -> Void)? = nil
    var onActivate: (() -> Void)? = nil
    var onPasteImage: ((PlatformImage) -> Void)? = nil
    @Environment(NotesStore.self) private var store

    func makeCoordinator() -> Coordinator { Coordinator(store: store, noteID: noteID, blockID: block.id) }

    func makeUIView(context: Context) -> CanvasHost {
        let host = CanvasHost()
        let canvas = host.canvas
        canvas.delegate = context.coordinator
        canvas.tool = ToolPickerCenter.shared.picker.selectedTool
        context.coordinator.canvas = canvas
        context.coordinator.load(block)
        if block.background != nil {
            // Auf Bildern und PDFs Farben nicht für den Dunkelmodus umkehren.
            canvas.overrideUserInterfaceStyle = .light
        }
        ToolPickerCenter.shared.picker.addObserver(canvas)
        apply(host, context.coordinator)
        return host
    }

    func updateUIView(_ host: CanvasHost, context: Context) {
        context.coordinator.block = block
        if block.drawing != context.coordinator.lastSaved {
            context.coordinator.load(block)  // Änderung von einem anderen Gerät oder Teilen/Zusammenfügen
        }
        apply(host, context.coordinator)
    }

    private func apply(_ host: CanvasHost, _ coordinator: Coordinator) {
        coordinator.onActivate = onActivate
        host.canvas.onPasteImage = onPasteImage
        host.onFingerTap = onFingerTap
        host.onLongPress = onLongPress
        host.fingerDrawing = store.fingerDrawing
    }

    static func dismantleUIView(_ host: CanvasHost, coordinator: Coordinator) {
        coordinator.flush()
        ToolPickerCenter.shared.picker.removeObserver(host.canvas)
    }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let store: NotesStore
        let noteID: String
        let blockID: String
        var block: NoteBlock?
        weak var canvas: PKCanvasView?
        var lastSaved: String?
        /// Für die Vollbildansicht: Bildausschnitt hat sich geändert.
        var onViewportChange: (() -> Void)?
        var onActivate: (() -> Void)?
        private var pending: Task<Void, Never>?
        private var loading = false

        init(store: NotesStore, noteID: String, blockID: String) {
            self.store = store
            self.noteID = noteID
            self.blockID = blockID
        }

        func load(_ block: NoteBlock) {
            self.block = block
            lastSaved = block.drawing
            loading = true
            canvas?.drawing = InkTools.decode(block.drawing) ?? PKDrawing()
            loading = false
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            onActivate?()
            if ToolPickerCenter.shared.activeCanvas !== canvasView || !canvasView.isFirstResponder {
                ToolPickerCenter.shared.activate(canvasView)
            }
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !loading else { return }
            pending?.cancel()
            pending = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                if Task.isCancelled { return }
                self?.flush()
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) { onViewportChange?() }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { onViewportChange?() }

        func flush() {
            pending?.cancel()
            pending = nil
            guard let canvas else { return }
            let drawing = canvas.drawing
            let encoded = InkTools.encode(drawing)
            guard encoded != lastSaved else { return }
            lastSaved = encoded
            let bottom = InkTools.bottom(drawing)
            let blockID = blockID
            store.updateBlocks(noteID) { blocks in
                if !blocks.contains(where: { $0.id == blockID }) {
                    // Die freie Schreibfläche am Ende wird beim ersten Strich zum Abschnitt.
                    blocks.append(NoteBlock(id: blockID, kind: .canvas, height: NoteBlock.tailHeight))
                }
                guard let i = blocks.firstIndex(where: { $0.id == blockID }) else { return }
                blocks[i].drawing = encoded
                blocks[i].inkBottom = bottom
            }
        }
    }
}

/// Finger-Gesten, die andere Gesten (PencilKit, Scrollen) nicht verhindern können.
final class FingerTapRecognizer: UITapGestureRecognizer {
    override func canBePrevented(by preventing: UIGestureRecognizer) -> Bool { false }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

final class FingerLongPressRecognizer: UILongPressGestureRecognizer {
    override func canBePrevented(by preventing: UIGestureRecognizer) -> Bool { false }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

/// Zeichenfläche, die „Einsetzen“ (Cmd+V) für Bilder aus der Zwischenablage annimmt.
final class NoteCanvasView: PKCanvasView {
    var onPasteImage: ((UIImage) -> Void)?

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), onPasteImage != nil, UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        if let onPasteImage, UIPasteboard.general.hasImages, let image = UIPasteboard.general.image {
            onPasteImage(image)
        } else {
            super.paste(sender)
        }
    }
}

/// Hält die PencilKit-Fläche und skaliert sie auf die verfügbare Breite.
final class CanvasHost: UIView, UIGestureRecognizerDelegate {
    let canvas = NoteCanvasView()

    /// Fingertipp bzw. langes Drücken (logische Koordinaten der Fläche).
    var onFingerTap: ((CGPoint) -> Void)? { didSet { updateGestures() } }
    var onLongPress: ((CGPoint) -> Void)? { didSet { updateGestures() } }

    var fingerDrawing = false {
        didSet {
            canvas.drawingPolicy = fingerDrawing ? .anyInput : .pencilOnly
            updateGestures()
            configureEnclosingScrollView()
        }
    }

    private lazy var tap: UITapGestureRecognizer = {
        let t = FingerTapRecognizer(target: self, action: #selector(tapped(_:)))
        t.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        t.cancelsTouchesInView = false
        t.delegate = self
        return t
    }()

    private lazy var press: UILongPressGestureRecognizer = {
        let p = FingerLongPressRecognizer(target: self, action: #selector(pressed(_:)))
        p.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        p.cancelsTouchesInView = false
        p.minimumPressDuration = 0.55
        p.delegate = self
        return p
    }()

    private func updateGestures() {
        tap.isEnabled = onFingerTap != nil && !fingerDrawing
        press.isEnabled = onLongPress != nil && !fingerDrawing
        restrictFingerGestures()
    }

    /// PencilKit reagiert sonst auch auf Finger (Auswahl-Menü) und stiehlt den Fokus.
    private func restrictFingerGestures() {
        let pencil = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        let all = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        func walk(_ v: UIView) {
            for g in v.gestureRecognizers ?? [] where g !== tap && g !== press {
                if g === canvas.panGestureRecognizer || g === canvas.pinchGestureRecognizer { continue }
                g.allowedTouchTypes = fingerDrawing ? all : pencil
            }
            v.subviews.forEach(walk)
        }
        walk(canvas)
    }

    // Neben PencilKits und den Scroll-Gesten gleichzeitig erkennen.
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    private func logical(_ g: UIGestureRecognizer) -> CGPoint {
        let p = g.location(in: self)
        let z = max(bounds.width / CGFloat(canvasWidth), 0.0001)
        return CGPoint(x: p.x / z, y: p.y / z)
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        onFingerTap?(logical(g))
    }

    @objc private func pressed(_ g: UILongPressGestureRecognizer) {
        if g.state == .began { onLongPress?(logical(g)) }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.showsVerticalScrollIndicator = false
        canvas.showsHorizontalScrollIndicator = false
        canvas.drawingPolicy = .pencilOnly
        canvas.contentInsetAdjustmentBehavior = .never
        addSubview(canvas)
        canvas.addGestureRecognizer(tap)
        canvas.addGestureRecognizer(press)
        updateGestures()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
        guard bounds.width > 0 else { return }
        let zoom = bounds.width / CGFloat(canvasWidth)
        canvas.minimumZoomScale = zoom
        canvas.maximumZoomScale = zoom
        canvas.zoomScale = zoom
        canvas.contentSize = bounds.size
        canvas.contentOffset = .zero
        restrictFingerGestures()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        configureEnclosingScrollView()
    }

    /// Der Stift soll nie die Seite verschieben; beim Fingerzeichnen scrollt man mit zwei Fingern.
    private func configureEnclosingScrollView() {
        var v = superview
        while let current = v {
            if let scroll = current as? UIScrollView, !(scroll is PKCanvasView) {
                scroll.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
                scroll.panGestureRecognizer.minimumNumberOfTouches = fingerDrawing ? 2 : 1
                return
            }
            v = current.superview
        }
    }
}
#endif
