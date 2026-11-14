#if os(iOS)
import PencilKit
import SwiftUI

/// Vollbildansicht für eine PDF-Seite oder ein Bild: mit zwei Fingern zoomen und
/// verschieben, mit dem Pencil genau schreiben. Bei PDFs lässt sich blättern.
struct PageEditorView: View {
    let noteID: String
    @State var blockID: String
    @Environment(NotesStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let blocks = store.note(noteID)?.content ?? []
        let block = blocks.first { $0.id == blockID }
        let pages = siblings(of: block, in: blocks)
        let index = pages.firstIndex { $0.id == blockID } ?? 0
        NavigationStack {
            Group {
                if let block, let bg = block.background {
                    ZoomCanvas(noteID: noteID, block: block, background: bg)
                        .id(block.id)
                } else {
                    Color.clear
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .background(Color(white: 0.12))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationTitle(pages.count > 1 ? "Seite \(index + 1) von \(pages.count)" : "")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if pages.count > 1 {
                        Button("Vorherige Seite", systemImage: "chevron.up") { blockID = pages[index - 1].id }
                            .disabled(index == 0)
                        Button("Nächste Seite", systemImage: "chevron.down") { blockID = pages[index + 1].id }
                            .disabled(index >= pages.count - 1)
                    }
                    Button {
                        store.fingerDrawing.toggle()
                    } label: {
                        Label(store.fingerDrawing ? "Fingerzeichnen aus" : "Mit Finger zeichnen",
                              systemImage: store.fingerDrawing ? "hand.draw.fill" : "hand.draw")
                    }
                }
            }
        }
        .onDisappear { ToolPickerCenter.shared.hide() }
    }

    private func siblings(of block: NoteBlock?, in blocks: [NoteBlock]) -> [NoteBlock] {
        guard let bg = block?.background else { return [] }
        guard bg.kind == .pdf else { return block.map { [$0] } ?? [] }
        return blocks.filter { $0.background?.kind == .pdf && $0.background?.blob == bg.blob }
    }
}

struct ZoomCanvas: UIViewRepresentable {
    let noteID: String
    let block: NoteBlock
    let background: Background
    @Environment(NotesStore.self) private var store

    func makeCoordinator() -> CanvasRepresentable.Coordinator {
        CanvasRepresentable.Coordinator(store: store, noteID: noteID, blockID: block.id)
    }

    func makeUIView(context: Context) -> ZoomHost {
        let host = ZoomHost(logicalSize: CGSize(width: canvasWidth, height: block.canvasHeight))
        let canvas = host.canvas
        canvas.delegate = context.coordinator
        canvas.tool = ToolPickerCenter.shared.picker.selectedTool
        context.coordinator.canvas = canvas
        context.coordinator.load(block)
        context.coordinator.onViewportChange = { [weak host] in host?.sync() }
        canvas.drawingPolicy = store.fingerDrawing ? .anyInput : .pencilOnly
        let bg = background
        let blobs = store.blobs
        Task { @MainActor [weak host] in
            // Hohe Auflösung, damit die Seite auch vergrößert scharf bleibt.
            let image = await BackgroundCache.shared.image(for: bg, width: 1200, blobs: blobs)
            host?.imageView.image = image
        }
        return host
    }

    func updateUIView(_ host: ZoomHost, context: Context) {
        if block.drawing != context.coordinator.lastSaved {
            context.coordinator.load(block)
        }
        host.canvas.drawingPolicy = store.fingerDrawing ? .anyInput : .pencilOnly
    }

    static func dismantleUIView(_ host: ZoomHost, coordinator: CanvasRepresentable.Coordinator) {
        coordinator.flush()
        ToolPickerCenter.shared.picker.removeObserver(host.canvas)
    }
}

final class ZoomHost: UIView {
    let canvas = PKCanvasView()
    let imageView = UIImageView()
    private let logicalSize: CGSize
    private var configured = false
    private var syncing = false

    init(logicalSize: CGSize) {
        self.logicalSize = logicalSize
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.12, alpha: 1)
        imageView.backgroundColor = .white
        imageView.contentMode = .scaleToFill
        addSubview(imageView)
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.showsVerticalScrollIndicator = false
        canvas.showsHorizontalScrollIndicator = false
        canvas.bouncesZoom = true
        addSubview(canvas)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let fitWidth = bounds.width / logicalSize.width
        let fitAll = min(fitWidth, bounds.height / logicalSize.height)
        canvas.minimumZoomScale = fitAll
        canvas.maximumZoomScale = fitWidth * 6
        if !configured {
            configured = true
            canvas.zoomScale = 1
            canvas.contentSize = logicalSize
            canvas.zoomScale = fitWidth
        } else if canvas.zoomScale < fitAll {
            canvas.zoomScale = fitAll
        }
        sync()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            ToolPickerCenter.shared.activate(self.canvas)
        }
    }

    /// Hintergrundbild an Zoom und Ausschnitt der Zeichenfläche angleichen.
    func sync() {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        let size = CGSize(width: logicalSize.width * canvas.zoomScale, height: logicalSize.height * canvas.zoomScale)
        let ix = max(0, (bounds.width - size.width) / 2)
        let iy = max(0, (bounds.height - size.height) / 2)
        let inset = UIEdgeInsets(top: iy, left: ix, bottom: iy, right: ix)
        if canvas.contentInset != inset { canvas.contentInset = inset }
        imageView.frame = CGRect(x: -canvas.contentOffset.x, y: -canvas.contentOffset.y,
                                 width: size.width, height: size.height)
    }
}
#endif
