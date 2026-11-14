import PhotosUI
import QuickLook
import SwiftUI

/// Wohin ein Bild eingefügt wird.
enum InsertTarget {
    /// Als eigener Block im Fluss (nach einem Block oder am Ende).
    case flow(after: String?)
    /// Frei auf einer Handschrift-Fläche, optional an einer Stelle (logische Koordinaten).
    case place(blockID: String, at: CGPoint?)
}

struct BlockRef: Identifiable {
    let id: String
}

struct PlaceRequest {
    let block: NoteBlock
    let point: CGPoint
    let isTail: Bool
}

struct NoteEditorView: View {
    let noteID: String
    @Environment(NotesStore.self) private var store
    @FocusState private var focusedBlock: String?
    /// Textblock, der gerade als Rohtext bearbeitet wird.
    @State private var editingBlock: String?
    @State private var showPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFiles = false
    @State private var showScanner = false
    @State private var showCamera = false
    @State private var importing = false
    @State private var insertTarget: InsertTarget = .flow(after: nil)
    /// ID der freien Schreibfläche am Ende; wird beim ersten Strich zum echten Abschnitt.
    @State private var tailID = UUID().uuidString
    /// PDFs, deren Seiten eingeklappt sind (nur auf diesem Gerät).
    @State private var collapsed: Set<String> = []
    @State private var exportURL: URL?
    @State private var fullScreen: BlockRef?
    @State private var placeRequest: PlaceRequest?
    @State private var contentWidth: CGFloat = 0
    /// Zeichenfläche, auf der zuletzt geschrieben wurde (Ziel fürs Einsetzen).
    @State private var activeCanvas: String?
    @State private var clipboardHasImage = false
    /// Stand vor dem letzten Löschen – für „Rückgängig“.
    @State private var undo: (blocks: [NoteBlock], message: String)?
    @State private var undoTask: Task<Void, Never>?
    @State private var showLockSheet = false
    @State private var showRecorder = false

    var body: some View {
        if store.isClosed(noteID) {
            LockedNoteView(noteID: noteID)
                .navigationTitle("")
        } else if let note = store.note(noteID) {
            let blocks = note.content.filter { !$0.isOverlay }
            let visible = blocks.filter { b in
                guard let bg = b.background, bg.kind == .pdf else { return true }
                return !collapsed.contains(bg.blob)
            }
            let items = visible + (showsTail(blocks, note) ? [tailBlock] : [])
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    Text(note.modifiedDate.formatted(date: .long, time: .shortened))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)

                    ForEach(items) { block in
                        blockView(block, blocks: blocks)
                    }

                    #if os(macOS)
                    // Freie Fläche unten: anklicken, um weiterzuschreiben.
                    Color.clear
                        .frame(height: 240)
                        .contentShape(Rectangle())
                        .onTapGesture { focusEnd(blocks) }
                    #endif
                }
                .background(GeometryReader { g in
                    Color.clear.preference(key: ContentSizeKey.self, value: g.size)
                })
                .onPreferenceChange(ContentSizeKey.self) { contentWidth = $0.width }
                .padding(.horizontal, 18)
                .frame(maxWidth: 920)
                .frame(maxWidth: .infinity)
                .disabled(note.trashed)
            }
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationTitle("")
            .toolbar { toolbar(note) }
            .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 20, matching: .images)
            .onChange(of: photoItems) { _, items in importPhotos(items) }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { importFiles(urls) }
            }
            .quickLookPreview($exportURL)
            // [[Titel]]-Links: zur Notiz springen bzw. sie anlegen.
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "notizen", url.host == "note" else { return .systemAction }
                let title = String(url.path.dropFirst()).removingPercentEncoding ?? String(url.path.dropFirst())
                store.openNote(titled: title, from: noteID)
                return .handled
            })
            .sheet(isPresented: $showRecorder) {
                AudioRecorderSheet { url, _ in addAudio(url) }
            }
            .sheet(isPresented: $showLockSheet) {
                LockPasswordSheet { pw in
                    LockSettings.remember(pw)
                    store.lock(noteID, password: pw)
                }
            }
            // Bilder per Drag & Drop: ans Ende der Notiz.
            .onDrop(of: [.image], isTargeted: nil) { providers in
                insertTarget = .flow(after: nil)
                importProviders(providers)
                return true
            }
            #if os(macOS)
            .onPasteCommand(of: [.image]) { providers in
                insertTarget = pasteTarget(blocks)
                importProviders(providers)
            }
            #else
            .overlay(alignment: .bottomTrailing) {
                // Liegt ein Bild in der Zwischenablage, lässt es sich mit einem Tipp einsetzen.
                if clipboardHasImage, !note.trashed {
                    PasteButton(supportedContentTypes: [.image]) { providers in
                        insertTarget = pasteTarget(blocks)
                        importProviders(providers)
                    }
                    .labelStyle(.titleAndIcon)
                    .buttonBorderShape(.capsule)
                    .padding(.trailing, 20)
                    .padding(.bottom, 24)
                }
            }
            .onAppear { clipboardHasImage = UIPasteboard.general.hasImages }
            .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
                clipboardHasImage = UIPasteboard.general.hasImages
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                clipboardHasImage = UIPasteboard.general.hasImages
            }
            #endif
            #if os(iOS)
            .fullScreenCover(isPresented: $showScanner) {
                DocumentScanner { images in
                    showScanner = false
                    importImages(images)
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in
                    showCamera = false
                    if let image { importImages([image]) }
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(item: $fullScreen) { ref in
                PageEditorView(noteID: noteID, blockID: ref.id)
            }
            .confirmationDialog(
                "Hier einfügen",
                isPresented: Binding(get: { placeRequest != nil }, set: { if !$0 { placeRequest = nil } }),
                titleVisibility: .visible,
                presenting: placeRequest
            ) { request in
                Button("Foto aus der Mediathek") {
                    insertTarget = .place(blockID: request.block.id, at: request.point)
                    showPhotos = true
                }
                if CameraPicker.isAvailable {
                    Button("Foto aufnehmen") {
                        insertTarget = .place(blockID: request.block.id, at: request.point)
                        showCamera = true
                    }
                }
                if UIPasteboard.general.hasImages {
                    Button("Bild aus der Zwischenablage") {
                        insertTarget = .place(blockID: request.block.id, at: request.point)
                        pasteImage()
                    }
                }
                Button("Text") { textAt(request, blocks: blocks) }
            }
            #endif
            .overlay(alignment: .bottom) {
                if let undo {
                    HStack(spacing: 14) {
                        Text(undo.message).font(.callout)
                        Button("Rückgängig") { restoreUndo() }
                            .font(.callout.weight(.semibold))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 6, y: 2)
                    .padding(.bottom, 28)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.3), value: undo?.message)
            .overlay {
                if importing {
                    ProgressView("Wird eingefügt …")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .onAppear {
                // Neue Notiz: auf dem iPad gleich mit dem Pencil loslegen,
                // auf iPhone und Mac direkt tippen.
                if note.isBlank, !Self.isPad, let first = blocks.first(where: { $0.kind == .text }) {
                    editingBlock = first.id
                }
            }
            .onChange(of: blocks.map(\.id)) { _, ids in
                // Die Schreibfläche wurde beschrieben – die nächste bekommt eine neue ID.
                if ids.contains(tailID) { tailID = UUID().uuidString }
            }
            .onChange(of: focusedBlock) { _, new in
                if let new {
                    editingBlock = new
                    activeCanvas = nil
                } else {
                    // Fokus verlassen → wieder formatiert anzeigen und aufräumen.
                    editingBlock = nil
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(500))
                        if focusedBlock == nil { store.tidy(noteID, keeping: editingBlock) }
                    }
                }
            }
            #if os(iOS)
            .onDisappear { ToolPickerCenter.shared.hide() }
            #endif
        }
    }

    // MARK: - Schreibfläche am Ende

    private static var isPad: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }

    private var tailBlock: NoteBlock {
        NoteBlock(id: tailID, kind: .canvas, height: NoteBlock.tailHeight)
    }

    /// Unter dem letzten Inhalt liegt immer eine freie Fläche für den Pencil –
    /// außer die Notiz endet schon mit einem Handschrift-Abschnitt (der wächst selbst mit).
    private func showsTail(_ blocks: [NoteBlock], _ note: Note) -> Bool {
        #if os(iOS)
        if note.trashed { return false }
        return !(blocks.last?.isInk ?? false)
        #else
        return false
        #endif
    }

    /// Wohin eingesetzt wird: hinter den Text, in dem getippt wird; auf die Handschrift-Fläche,
    /// auf der zuletzt geschrieben wurde; sonst ans Ende.
    private func pasteTarget(_ blocks: [NoteBlock]) -> InsertTarget {
        if let focusedBlock { return .flow(after: focusedBlock) }
        if let activeCanvas {
            if activeCanvas == tailID { return .place(blockID: activeCanvas, at: nil) }
            if let b = blocks.first(where: { $0.id == activeCanvas }) {
                return b.isInk ? .place(blockID: b.id, at: nil) : .flow(after: b.id)
            }
        }
        return .flow(after: nil)
    }

    private func focus(_ id: String) {
        #if os(iOS)
        // Zeichenfläche und Werkzeugleiste freigeben, sonst holt sich PencilKit den Fokus zurück.
        ToolPickerCenter.shared.hide()
        #endif
        editingBlock = id
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            editingBlock = id
            focusedBlock = id
        }
    }

    private func focusEnd(_ blocks: [NoteBlock]) {
        if let last = blocks.last, last.kind == .text {
            focus(last.id)
        } else if let last = blocks.last, let id = store.textAfter(noteID, last.id) {
            focus(id)
        } else {
            let block = NoteBlock.text()
            store.insert([block], into: noteID)
            focus(block.id)
        }
    }

    /// Fingertipp auf eine Zeichenfläche.
    private func canvasTap(_ block: NoteBlock, at p: CGPoint, blocks: [NoteBlock]) {
        if block.id == tailID {
            focusEnd(blocks)
            return
        }
        guard block.isInk else { return }
        if Double(p.y) > block.contentBottom + 30 {
            // Unter der Handschrift: dort weiterschreiben.
            if let id = store.textAfter(noteID, block.id) { focus(id) }
        } else if let id = store.splitInk(noteID, block.id, atY: Double(p.y)) {
            // In einer Lücke zwischen Handschrift: Text dazwischen.
            focus(id)
        }
    }

    #if os(iOS)
    private func textAt(_ request: PlaceRequest, blocks: [NoteBlock]) {
        if request.isTail {
            focusEnd(blocks)
        } else if let id = store.splitInk(noteID, request.block.id, atY: Double(request.point.y))
                    ?? store.textAfter(noteID, request.block.id) {
            focus(id)
        }
    }
    #endif

    // MARK: - Blöcke

    @ViewBuilder
    private func blockView(_ block: NoteBlock, blocks: [NoteBlock]) -> some View {
        let index = blocks.firstIndex { $0.id == block.id }
        switch block.kind {
        case .text:
            TextBlockView(noteID: noteID, block: block, editing: $editingBlock, focus: $focusedBlock)
                .contextMenu { blockMenuItems(block, index: index, count: blocks.count) }
        case .canvas:
            let isTail = block.id == tailID
            CanvasBlockView(
                noteID: noteID, block: block,
                onTap: { p in canvasTap(block, at: p, blocks: blocks) },
                onLongPress: block.isInk ? { p in
                    placeRequest = PlaceRequest(block: block, point: p, isTail: isTail)
                } : nil,
                paper: store.note(noteID)?.paper ?? "blank",
                onActivate: { activeCanvas = block.id },
                onPasteImage: { image in
                    insertTarget = block.isInk ? .place(blockID: block.id, at: nil) : .flow(after: block.id)
                    importImages([image])
                })
            .frame(maxWidth: width(for: block))
            .onDrop(of: [.image], isTargeted: nil) { providers, location in
                // Auf Handschrift-Flächen landet das Bild dort, wo es losgelassen wird.
                if block.isInk, contentWidth > 0 {
                    let z = contentWidth / CGFloat(canvasWidth)
                    insertTarget = .place(blockID: block.id, at: CGPoint(x: location.x / z, y: location.y / z))
                } else {
                    insertTarget = .flow(after: block.id)
                }
                importProviders(providers)
                return true
            }
            .overlay(alignment: .topTrailing) {
                if !isTail { canvasButtons(block, index: index, count: blocks.count) }
            }
            .overlay(alignment: .bottomLeading) {
                if let bg = block.background, bg.kind == .pdf {
                    Text("Seite \((bg.page ?? 0) + 1)")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.regularMaterial, in: Capsule())
                        .padding(8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .file:
            if let file = block.file {
                VStack(alignment: .leading, spacing: 6) {
                    Group {
                        if file.isAudio {
                            AudioBlockView(file: file, transcript: block.recognized,
                                           transcribing: block.needsRecognition)
                        } else {
                            FileBlockView(file: file)
                        }
                    }
                    .contextMenu { blockMenuItems(block, index: index, count: blocks.count) }
                    if file.type == "com.adobe.pdf" {
                        pdfBar(file, blocks: blocks)
                    }
                }
            }
        }
    }

    private func width(for block: NoteBlock) -> CGFloat {
        guard contentWidth > 0 else { return .infinity }
        // Auf schmalen Bildschirmen (iPhone) Bilder nicht zu klein zeigen.
        let scale = contentWidth < 500 ? max(block.displayScale, 0.85) : block.displayScale
        return contentWidth * CGFloat(scale)
    }

    /// Leiste unter einem PDF: Seiten ein-/ausklappen, mit Anmerkungen teilen, entfernen.
    private func pdfBar(_ file: FileRef, blocks: [NoteBlock]) -> some View {
        let pages = blocks.filter { $0.background?.kind == .pdf && $0.background?.blob == file.blob }
        let isCollapsed = collapsed.contains(file.blob)
        return HStack(spacing: 16) {
            if !pages.isEmpty {
                let count = pages.count == 1 ? "1 Seite" : "\(pages.count) Seiten"
                Button {
                    if isCollapsed { collapsed.remove(file.blob) } else { collapsed.insert(file.blob) }
                } label: {
                    Label(isCollapsed ? "\(count) einblenden" : "\(count) ausblenden",
                          systemImage: isCollapsed ? "chevron.right" : "chevron.down")
                }
            }
            Button {
                exportPDF(file, pages: pages)
            } label: {
                Label("Mit Anmerkungen teilen", systemImage: "square.and.arrow.up.on.square")
            }
            Spacer()
            Menu {
                Button("PDF samt Seiten entfernen", systemImage: "trash", role: .destructive) {
                    withUndo("PDF entfernt") { store.removePDF(noteID, blob: file.blob) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
        }
        .font(.footnote)
        .buttonStyle(.borderless)
        .padding(.horizontal, 4)
    }

    private func exportPDF(_ file: FileRef, pages: [NoteBlock]) {
        guard store.blobs.exists(file.blob) else { return }
        var ink: [Int: String] = [:]
        for p in pages {
            if let page = p.background?.page, let d = p.drawing { ink[page] = d }
        }
        exportURL = PDFExporter.export(source: store.blobs.url(file.blob), name: file.name, ink: ink)
    }

    private func canvasButtons(_ block: NoteBlock, index: Int?, count: Int) -> some View {
        HStack(spacing: 2) {
            #if os(iOS)
            if block.background != nil {
                Button {
                    fullScreen = BlockRef(id: block.id)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.black.opacity(0.35))
                }
                .buttonStyle(.plain)
            }
            #endif
            Menu {
                blockMenuItems(block, index: index, count: count)
            } label: {
                Image(systemName: block.isInk ? "ellipsis" : "ellipsis.circle.fill")
                    .font(block.isInk ? .footnote : .title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(block.isInk ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.white),
                                     Color.black.opacity(0.35))
                    .padding(block.isInk ? 6 : 0)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
        }
        .padding(8)
    }

    @ViewBuilder
    private func blockMenuItems(_ block: NoteBlock, index: Int?, count: Int) -> some View {
        if block.kind == .canvas {
            if block.isInk {
                Button("Bild auf die Fläche legen", systemImage: "photo.badge.plus") {
                    insertTarget = .place(blockID: block.id, at: nil)
                    showPhotos = true
                }
            }
            if block.background?.kind == .image {
                Menu("Größe", systemImage: "arrow.up.left.and.arrow.down.right") {
                    Button("Klein") { store.updateBlock(noteID, block.id) { $0.scale = 0.4 } }
                    Button("Mittel") { store.updateBlock(noteID, block.id) { $0.scale = 0.66 } }
                    Button("Groß") { store.updateBlock(noteID, block.id) { $0.scale = 1 } }
                }
            }
            #if os(iOS)
            if block.background != nil {
                Button("Vollbild mit Zoom", systemImage: "arrow.up.left.and.arrow.down.right") {
                    fullScreen = BlockRef(id: block.id)
                }
            }
            #endif
            if let text = block.recognized, !text.isEmpty {
                Button(block.isInk ? "Handschrift als Text darunter" : "Erkannten Text darunter einfügen",
                       systemImage: "text.badge.plus") {
                    store.insert([NoteBlock.text(text)], into: noteID, after: block.id)
                }
                Button("Erkannten Text kopieren", systemImage: "doc.on.doc") {
                    #if os(iOS)
                    UIPasteboard.general.string = text
                    #else
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    #endif
                }
            } else if block.needsRecognition {
                Text("Text wird erkannt …")
            }
            if block.hasInk {
                Button("Handschrift entfernen", systemImage: "eraser") {
                    withUndo("Handschrift entfernt") {
                        store.updateBlock(noteID, block.id) { $0.drawing = nil; $0.inkBottom = nil }
                    }
                }
            }
        }
        Button("Bild darunter einfügen", systemImage: "photo.on.rectangle") {
            insertTarget = .flow(after: block.id)
            showPhotos = true
        }
        if let index {
            if index > 0 {
                Button("Nach oben", systemImage: "arrow.up") { store.moveBlock(noteID, block.id, by: -1) }
            }
            if index < count - 1 {
                Button("Nach unten", systemImage: "arrow.down") { store.moveBlock(noteID, block.id, by: 1) }
            }
        }
        Divider()
        Button(block.background?.kind == .pdf ? "Seite löschen" : "Löschen", systemImage: "trash", role: .destructive) {
            let what = block.kind == .text ? "Text" : block.background?.kind == .pdf ? "Seite"
                : block.background != nil ? "Bild" : block.kind == .file ? "Datei" : "Handschrift"
            withUndo("\(what) gelöscht") { store.deleteBlock(noteID, block.id) }
        }
    }

    // MARK: - Werkzeugleiste

    @ToolbarContentBuilder
    private func toolbar(_ note: Note) -> some ToolbarContent {
        if note.trashed {
            ToolbarItem(placement: .primaryAction) {
                Button("Wiederherstellen", systemImage: "arrow.uturn.backward") { store.restore(noteID) }
            }
        } else {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("Text", systemImage: "text.alignleft") { addText() }
                    Button("Foto aus der Mediathek", systemImage: "photo.on.rectangle") {
                        insertTarget = .flow(after: focusedBlock)
                        showPhotos = true
                    }
                    #if os(iOS)
                    if CameraPicker.isAvailable {
                        Button("Foto aufnehmen", systemImage: "camera") {
                            insertTarget = .flow(after: focusedBlock)
                            showCamera = true
                        }
                    }
                    if DocumentScanner.isAvailable {
                        Button("Dokument scannen", systemImage: "doc.viewfinder") {
                            insertTarget = .flow(after: focusedBlock)
                            showScanner = true
                        }
                    }
                    if UIPasteboard.general.hasImages {
                        Button("Bild aus der Zwischenablage", systemImage: "doc.on.clipboard") {
                            insertTarget = .flow(after: focusedBlock)
                            pasteImage()
                        }
                    }
                    #endif
                    Button("Sprachnotiz aufnehmen", systemImage: "mic") { showRecorder = true }
                    Button("Datei oder PDF", systemImage: "paperclip") { showFiles = true }
                } label: {
                    Label("Einfügen", systemImage: "plus.circle")
                }

                #if os(iOS)
                Button {
                    store.fingerDrawing.toggle()
                } label: {
                    Label(store.fingerDrawing ? "Fingerzeichnen aus" : "Mit Finger zeichnen",
                          systemImage: store.fingerDrawing ? "hand.draw.fill" : "hand.draw")
                }
                #endif

                Menu {
                    Button(note.pinned ? "Lösen" : "Anpinnen", systemImage: note.pinned ? "pin.slash" : "pin") {
                        store.togglePin(noteID)
                    }
                    Picker(selection: Binding(get: { note.paper }, set: { store.setPaper(noteID, $0) })) {
                        Label("Blanko", systemImage: "rectangle.portrait").tag("blank")
                        Label("Liniert", systemImage: "line.3.horizontal").tag("lined")
                        Label("Kariert", systemImage: "squareshape.split.3x3").tag("grid")
                    } label: {
                        Label("Papier", systemImage: "doc.plaintext")
                    }
                    .pickerStyle(.menu)
                    if note.isLocked {
                        Button("Jetzt sperren", systemImage: "lock") { store.relock(noteID) }
                        Button("Sperre entfernen", systemImage: "lock.open") { store.removeLock(noteID) }
                    } else {
                        Button("Notiz sperren", systemImage: "lock") { lockNote() }
                    }
                    Button("Als PDF teilen oder drucken", systemImage: "doc.richtext") {
                        exportURL = NoteExporter.exportPDF(note, blobs: store.blobs)
                    }
                    ShareLink(item: note.text) {
                        Label("Text teilen", systemImage: "square.and.arrow.up")
                    }
                    Divider()
                    Button("Notiz löschen", systemImage: "trash", role: .destructive) {
                        store.trash(noteID)
                    }
                } label: {
                    Label("Mehr", systemImage: "ellipsis.circle")
                }
            }
        }
    }

    /// Mit gespeichertem Passwort (Face ID / Touch ID) sperren, sonst Passwort festlegen.
    private func lockNote() {
        guard LockSettings.hasSavedPassword else { showLockSheet = true; return }
        Task {
            if let pw = await LockKeychain.load(reason: "Notiz sperren") {
                store.lock(noteID, password: pw)
            } else {
                showLockSheet = true
            }
        }
    }

    // MARK: - Rückgängig

    private func withUndo(_ message: String, _ action: () -> Void) {
        guard let before = store.note(noteID)?.content else { action(); return }
        action()
        undo = (before, message)
        undoTask?.cancel()
        undoTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled { undo = nil }
        }
    }

    private func restoreUndo() {
        guard let undo else { return }
        let blocks = undo.blocks
        store.updateBlocks(noteID) { $0 = blocks }
        self.undo = nil
        undoTask?.cancel()
    }

    // MARK: - Einfügen

    private func addText() {
        let block = NoteBlock.text()
        store.insert([block], into: noteID, after: focusedBlock)
        focus(block.id)
    }

    /// Speichert Bilder im Hintergrund und fügt sie dann am gewählten Ziel ein.
    private func addImages(_ work: @escaping @Sendable (BlobStore) async -> [(blob: String, aspect: Double)]) {
        let target = insertTarget
        insertTarget = .flow(after: nil)
        let blobs = store.blobs
        importing = true
        Task {
            let stored = await Task.detached(priority: .userInitiated) { await work(blobs) }.value
            switch target {
            case .flow(let after):
                store.insert(stored.map { Importer.imageBlock(blob: $0.blob, aspect: $0.aspect) },
                             into: noteID, after: after)
            case .place(let blockID, let point):
                for (i, s) in stored.enumerated() {
                    let p = point.map { CGPoint(x: $0.x + CGFloat(i) * 40, y: $0.y + CGFloat(i) * 40) }
                    store.placeImage(noteID, blockID, blob: s.blob, aspect: s.aspect, at: p)
                }
            }
            importing = false
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        photoItems = []
        addImages { blobs in
            var out: [(blob: String, aspect: Double)] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = PlatformImage(data: data),
                   let stored = Importer.storeImage(image, blobs: blobs) {
                    out.append(stored)
                }
            }
            return out
        }
    }

    private func importImages(_ images: [PlatformImage]) {
        guard !images.isEmpty else { return }
        nonisolated(unsafe) let imgs = images
        addImages { blobs in imgs.compactMap { Importer.storeImage($0, blobs: blobs) } }
    }

    /// Bilder aus Drag & Drop oder der Zwischenablage laden und einfügen.
    private func importProviders(_ providers: [NSItemProvider]) {
        let usable = providers.filter { $0.hasItemConformingToTypeIdentifier("public.image") }
        guard !usable.isEmpty else { return }
        nonisolated(unsafe) let items = usable
        addImages { blobs in
            var out: [(blob: String, aspect: Double)] = []
            for provider in items {
                let data: Data? = await withCheckedContinuation { cont in
                    _ = provider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in
                        cont.resume(returning: data)
                    }
                }
                if let data, let image = PlatformImage(data: data),
                   let stored = Importer.storeImage(image, blobs: blobs) {
                    out.append(stored)
                }
            }
            return out
        }
    }

    #if os(iOS)
    private func pasteImage() {
        if let image = UIPasteboard.general.image { importImages([image]) }
    }
    #endif

    private func addAudio(_ url: URL) {
        let after = focusedBlock
        guard let data = try? Data(contentsOf: url), let sha = try? store.blobs.put(data) else { return }
        try? FileManager.default.removeItem(at: url)
        let name = "Sprachnotiz \(Date().formatted(date: .numeric, time: .shortened)).m4a"
        let block = NoteBlock(kind: .file, file: FileRef(blob: sha, name: name, size: data.count, type: "com.apple.m4a-audio"))
        store.insert([block], into: noteID, after: after)
    }

    private func importFiles(_ urls: [URL]) {
        let after = focusedBlock
        let blobs = store.blobs
        importing = true
        Task {
            let blocks = await Task.detached(priority: .userInitiated) {
                urls.flatMap { Importer.fileBlocks($0, blobs: blobs) }
            }.value
            store.insert(blocks, into: noteID, after: after)
            importing = false
        }
    }
}

/// Textblock: zeigt formatierten Text, beim Antippen den Rohtext zum Bearbeiten.
struct TextBlockView: View {
    let noteID: String
    let block: NoteBlock
    @Binding var editing: String?
    var focus: FocusState<String?>.Binding
    @Environment(NotesStore.self) private var store
    @State private var selection: TextSelection?

    var body: some View {
        let text = block.text ?? ""
        let isEditing = editing == block.id || focus.wrappedValue == block.id
        if isEditing || text.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if isEditing {
                    FormatBar { format in apply(format) }
                }
                GrowingTextEditor(text: binding, selection: $selection)
                    .focused(focus, equals: block.id)
            }
            .onAppear {
                if editing == block.id { focus.wrappedValue = block.id }
            }
            .onChange(of: editing) { _, new in
                if new == block.id { focus.wrappedValue = block.id }
            }
        } else {
            RichTextView(text: text) { line in
                store.updateBlock(noteID, block.id) {
                    $0.text = RichTextView.toggleCheckbox(in: $0.text ?? "", line: line)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { editing = block.id }
        }
    }

    private var binding: Binding<String> {
        Binding(
            get: { store.note(noteID)?.content.first { $0.id == block.id }?.text ?? "" },
            set: { value in store.updateBlock(noteID, block.id) { $0.text = value } })
    }

    /// Formatierung auf Auswahl bzw. aktuelle Zeile anwenden.
    private func apply(_ format: TextFormat) {
        let text = binding.wrappedValue
        var range = text.count..<text.count
        if case .selection(let r)? = selection?.indices {
            let lower = text.distance(from: text.startIndex, to: min(r.lowerBound, text.endIndex))
            let upper = text.distance(from: text.startIndex, to: min(r.upperBound, text.endIndex))
            range = lower..<max(lower, upper)
        }
        let (newText, newRange) = format.apply(to: text, selection: range)
        binding.wrappedValue = newText
        let lo = newText.index(newText.startIndex, offsetBy: min(newRange.lowerBound, newText.count))
        let hi = newText.index(newText.startIndex, offsetBy: min(newRange.upperBound, newText.count))
        selection = TextSelection(range: lo..<hi)
        focus.wrappedValue = block.id
    }
}

/// Mehrzeiliger Editor, der mit dem Text mitwächst (die Eingabetaste erzeugt eine neue Zeile).
struct GrowingTextEditor: View {
    @Binding var text: String
    @Binding var selection: TextSelection?

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Unsichtbarer Text bestimmt die Höhe.
            Text(text.isEmpty ? " " : text + "\n")
                .font(.body)
                .padding(.vertical, 8)
                .padding(.horizontal, 5)
                .opacity(0)
                .accessibilityHidden(true)
            if text.isEmpty {
                Text("Text")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 5)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text, selection: $selection)
                .font(.body)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .background(Color.clear)
        }
        .padding(.horizontal, -5)
    }
}

struct ContentSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}
