import Foundation
import PencilKit

/// Hilfen für Handschrift: kodieren, teilen, zusammenfügen.
enum InkTools {
    static func decode(_ base64: String?) -> PKDrawing? {
        guard let base64, let data = Data(base64Encoded: base64) else { return nil }
        return try? PKDrawing(data: data)
    }

    static func encode(_ drawing: PKDrawing) -> String? {
        drawing.strokes.isEmpty ? nil : drawing.dataRepresentation().base64EncodedString()
    }

    static func bottom(_ drawing: PKDrawing) -> Double {
        drawing.strokes.isEmpty ? 0 : Double(drawing.bounds.maxY)
    }

    static func shifted(_ drawing: PKDrawing, dy: Double) -> PKDrawing {
        drawing.transformed(using: CGAffineTransform(translationX: 0, y: CGFloat(dy)))
    }

    /// Teilt eine Zeichnung an einer waagerechten Lücke. `nil`, wenn dort ein Strich verläuft
    /// oder ober- bzw. unterhalb nichts steht.
    static func split(_ drawing: PKDrawing, atY y: Double) -> (top: PKDrawing, bottom: PKDrawing)? {
        var top: [PKStroke] = []
        var bottom: [PKStroke] = []
        for stroke in drawing.strokes {
            let b = stroke.renderBounds
            if Double(b.maxY) <= y {
                top.append(stroke)
            } else if Double(b.minY) >= y {
                bottom.append(stroke)
            } else {
                return nil
            }
        }
        return (PKDrawing(strokes: top), PKDrawing(strokes: bottom))
    }
}

extension NotesStore {
    /// Wandelt ältere Daten um: die frühere Handschrift-Ebene wird ein normaler Abschnitt,
    /// und Flächen ohne bekannte Unterkante bekommen sie nachgetragen.
    func migrateInk() {
        for note in notes where !note.deleted {
            guard let blocks = note.blocks,
                  blocks.contains(where: { $0.isOverlay || ($0.isInk && $0.hasInk && $0.inkBottom == nil) })
            else { continue }
            updateBlocks(note.id) { blocks in
                for i in blocks.indices where blocks[i].isInk && !blocks[i].isOverlay
                    && blocks[i].hasInk && blocks[i].inkBottom == nil {
                    if let d = InkTools.decode(blocks[i].drawing) { blocks[i].inkBottom = InkTools.bottom(d) }
                }
                guard let i = blocks.firstIndex(where: \.isOverlay) else { return }
                var ink = blocks.remove(at: i)
                ink.overlay = nil
                guard let d = InkTools.decode(ink.drawing), !d.strokes.isEmpty else { return }
                // Leerraum über der Handschrift entfernen und den Abschnitt hinter den Text setzen.
                let top = max(0, Double(d.bounds.minY) - 24)
                let moved = InkTools.shifted(d, dy: -top)
                ink.drawing = InkTools.encode(moved)
                ink.inkBottom = InkTools.bottom(moved)
                let lastText = blocks.lastIndex { $0.kind == .text && !$0.isEmpty }
                blocks.insert(ink, at: lastText.map { $0 + 1 } ?? 0)
            }
        }
    }

    /// Textblock direkt nach einem Block (vorhandenen nutzen, sonst anlegen). Gibt dessen ID zurück.
    @discardableResult
    func textAfter(_ noteID: String, _ blockID: String) -> String? {
        var result: String?
        updateBlocks(noteID) { blocks in
            guard let i = blocks.firstIndex(where: { $0.id == blockID }) else { return }
            if i + 1 < blocks.count, blocks[i + 1].kind == .text {
                result = blocks[i + 1].id
            } else {
                let t = NoteBlock.text()
                blocks.insert(t, at: i + 1)
                result = t.id
            }
        }
        return result
    }

    /// Teilt einen Handschrift-Abschnitt an einer Lücke und setzt einen Textblock dazwischen.
    func splitInk(_ noteID: String, _ blockID: String, atY y: Double) -> String? {
        guard let block = note(noteID)?.content.first(where: { $0.id == blockID }), block.isInk,
              let drawing = InkTools.decode(block.drawing),
              let parts = InkTools.split(drawing, atY: y) else { return nil }
        let images = block.images ?? []
        if images.contains(where: { $0.y < y && $0.y + $0.h > y }) { return nil }
        let topImages = images.filter { $0.y + $0.h <= y }
        let bottomImages = images.filter { $0.y >= y }
        guard !(parts.top.strokes.isEmpty && topImages.isEmpty),
              !(parts.bottom.strokes.isEmpty && bottomImages.isEmpty) else { return nil }
        let bottomTop = min(parts.bottom.strokes.isEmpty ? .infinity : Double(parts.bottom.bounds.minY),
                            bottomImages.map(\.y).min() ?? .infinity)
        let shift = max(0, bottomTop - 24)
        let lower = InkTools.shifted(parts.bottom, dy: -shift)
        let text = NoteBlock.text()
        updateBlocks(noteID) { blocks in
            guard let i = blocks.firstIndex(where: { $0.id == blockID }) else { return }
            blocks[i].drawing = InkTools.encode(parts.top)
            blocks[i].inkBottom = InkTools.bottom(parts.top)
            blocks[i].images = topImages.isEmpty ? nil : topImages
            var second = NoteBlock(kind: .canvas)
            second.drawing = InkTools.encode(lower)
            second.inkBottom = InkTools.bottom(lower)
            let movedImages = bottomImages.map { img -> PlacedImage in
                var m = img
                m.y -= shift
                return m
            }
            second.images = movedImages.isEmpty ? nil : movedImages
            blocks.insert(contentsOf: [text, second], at: i + 1)
        }
        return text.id
    }

    /// Räumt auf, wenn nicht mehr getippt wird: leere Textblöcke entfernen und
    /// direkt aufeinanderfolgende Handschrift-Abschnitte wieder zusammenfügen.
    func tidy(_ noteID: String, keeping keep: String? = nil) {
        guard let blocks = note(noteID)?.content else { return }
        let hasEmptyText = blocks.count > 1 && blocks.contains { $0.kind == .text && $0.isEmpty && $0.id != keep }
        guard hasEmptyText else { return }
        updateBlocks(noteID) { blocks in
            if blocks.count > 1 {
                blocks.removeAll { $0.kind == .text && $0.isEmpty && $0.id != keep }
            }
            if blocks.isEmpty { blocks = [.text()] }
            var i = 0
            while i + 1 < blocks.count {
                guard blocks[i].isInk, blocks[i + 1].isInk,
                      !(blocks[i].hasInk && blocks[i].inkBottom == nil),
                      !(blocks[i + 1].hasInk && blocks[i + 1].inkBottom == nil) else { i += 1; continue }
                let offset = blocks[i].contentBottom + 40
                var merged = InkTools.decode(blocks[i].drawing) ?? PKDrawing()
                if let lower = InkTools.decode(blocks[i + 1].drawing) {
                    merged.append(InkTools.shifted(lower, dy: offset))
                }
                blocks[i].drawing = InkTools.encode(merged)
                blocks[i].inkBottom = InkTools.bottom(merged)
                let moved = (blocks[i + 1].images ?? []).map { img -> PlacedImage in
                    var m = img
                    m.y += offset
                    return m
                }
                let all = (blocks[i].images ?? []) + moved
                blocks[i].images = all.isEmpty ? nil : all
                blocks.remove(at: i + 1)
            }
        }
    }

    /// Legt ein Bild frei auf eine Handschrift-Fläche (die Fläche entsteht bei Bedarf).
    func placeImage(_ noteID: String, _ blockID: String, blob: String, aspect: Double, at point: CGPoint?) {
        updateBlocks(noteID) { blocks in
            if !blocks.contains(where: { $0.id == blockID }) {
                blocks.append(NoteBlock(id: blockID, kind: .canvas, height: NoteBlock.tailHeight))
            }
            guard let i = blocks.firstIndex(where: { $0.id == blockID }) else { return }
            let w = 420.0
            let h = w * aspect
            let x = point.map { min(max(0, Double($0.x) - w / 2), canvasWidth - w) } ?? (canvasWidth - w) / 2
            let y = point.map { max(0, Double($0.y) - h / 2) } ?? blocks[i].contentBottom + 24
            blocks[i].images = (blocks[i].images ?? []) + [PlacedImage(blob: blob, x: x, y: y, w: w, h: h)]
        }
    }
}
