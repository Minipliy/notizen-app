import Foundation

func nowMillis() -> Double {
    (Date().timeIntervalSince1970 * 1000).rounded()
}

/// Logische Breite jeder Zeichenfläche. Auf iPhone und iPad wird sie passend skaliert,
/// damit Handschrift auf allen Geräten gleich aussieht.
let canvasWidth: Double = 1024

// MARK: - Blöcke

/// Ein Stück einer Notiz: Text, Zeichenfläche (auch über Bild/PDF-Seite) oder Datei.
struct NoteBlock: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case text, canvas, file
    }

    var id: String = UUID().uuidString
    var kind: Kind
    /// Text mit Markdown, Checklisten und LaTeX (`$…$`, `$$…$$`).
    var text: String?
    /// PencilKit-Zeichnung (Base64 von `PKDrawing.dataRepresentation()`).
    var drawing: String?
    /// Höhe einer leeren Zeichenfläche in logischen Punkten (Breite = `canvasWidth`).
    var height: Double?
    /// Bild oder PDF-Seite, auf die gezeichnet wird.
    var background: Background?
    /// Angehängte Datei (z. B. das Original-PDF).
    var file: FileRef?
    /// Veraltet: Handschrift-Ebene über der ganzen Notiz. Wird beim Laden in einen
    /// normalen Handschrift-Abschnitt umgewandelt.
    var overlay: Bool?
    /// Unterkante der Handschrift in logischen Punkten (für das automatische Zuschneiden).
    var inkBottom: Double?
    /// Frei platzierte Bilder auf einer Handschrift-Fläche.
    var images: [PlacedImage]?
    /// Anzeigebreite als Anteil der Notizbreite (nur Bilder), z. B. 0.66.
    var scale: Double?
    /// Papier der Notiz ("blank", "lined", "grid"). Steht an einem Block der Notiz und gilt
    /// für alle Handschrift-Abschnitte – so braucht der Server kein eigenes Feld dafür.
    var paper: String?
    /// Erkannter Text (Handschrift, Foto, PDF-Seite) – für Suche und Titel.
    var recognized: String?
    /// Inhalt, aus dem `recognized` stammt (siehe `recognitionSource`).
    var recognizedKey: String?
    /// Verschlüsselter Inhalt einer gesperrten Notiz (siehe `NoteCrypto`).
    var sealed: String?

    var isOverlay: Bool { overlay == true }

    /// Handschrift-Abschnitt: Zeichenfläche ohne Bild/PDF dahinter.
    var isInk: Bool { kind == .canvas && background == nil }

    /// Unterkante von Handschrift und platzierten Bildern.
    var contentBottom: Double {
        max(inkBottom ?? 0, (images ?? []).map { $0.y + $0.h }.max() ?? 0)
    }

    var displayScale: Double {
        guard background?.kind == .image else { return 1 }
        return min(1, max(0.2, scale ?? 1))
    }

    static func text(_ s: String = "") -> NoteBlock { NoteBlock(kind: .text, text: s) }
    static func canvas(height: Double = 1100) -> NoteBlock { NoteBlock(kind: .canvas, height: height) }

    /// Seitenverhältnis Höhe/Breite der Fläche.
    var canvasAspect: Double {
        if let bg = background { return max(0.05, bg.aspect) }
        return max(0.1, (height ?? 1100) / canvasWidth)
    }

    var canvasHeight: Double { canvasWidth * canvasAspect }

    var hasInk: Bool { !(drawing ?? "").isEmpty }

    var isEmpty: Bool {
        switch kind {
        case .text: return sealed == nil && (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .canvas: return !hasInk && background == nil && (images ?? []).isEmpty
        case .file: return file == nil
        }
    }

    var blobRefs: [String] {
        [background?.blob, file?.blob].compactMap { $0 } + (images ?? []).map(\.blob)
    }

    static let tailHeight: Double = 700

    /// Hält Handschrift-Abschnitte in Form: Abschnitte mitten in der Notiz werden auf ihren
    /// Inhalt zugeschnitten (leere verschwinden), der letzte behält Platz zum Weiterschreiben.
    static func normalize(_ blocks: inout [NoteBlock]) {
        let lastID = blocks.last?.id
        blocks.removeAll { b in
            guard b.isInk, !b.isOverlay, b.id != lastID else { return false }
            return b.isEmpty
        }
        for i in blocks.indices where blocks[i].isInk && !blocks[i].isOverlay {
            // Ältere Flächen ohne bekannte Unterkante nicht anfassen.
            if blocks[i].hasInk && blocks[i].inkBottom == nil { continue }
            let bottom = blocks[i].contentBottom
            if i == blocks.count - 1 {
                blocks[i].height = max(tailHeight, bottom + 600)
            } else {
                blocks[i].height = bottom + 90
            }
        }
    }
}

/// Bild, das frei auf einer Handschrift-Fläche liegt (Koordinaten in logischen Punkten).
struct PlacedImage: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var blob: String
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

struct Background: Codable, Equatable {
    enum Kind: String, Codable { case image, pdf }
    var kind: Kind
    /// SHA-256 des Anhangs.
    var blob: String
    /// Seitennummer bei PDFs (ab 0).
    var page: Int?
    /// Höhe/Breite.
    var aspect: Double
}

struct FileRef: Codable, Equatable {
    var blob: String
    var name: String
    var size: Int
    /// Uniform Type Identifier, z. B. "com.adobe.pdf".
    var type: String?
}

// MARK: - Notiz

struct Note: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var folderId: String? = nil
    /// Reiner Text aller Textblöcke – für Titel, Vorschau und Suche.
    var text: String = ""
    var blocks: [NoteBlock]? = nil
    var pinned: Bool = false
    /// Liegt in „Zuletzt gelöscht“.
    var trashed: Bool = false
    /// Endgültig gelöscht – bleibt nur als Markierung für den Abgleich bestehen.
    var deleted: Bool = false
    var createdAt: Double = nowMillis()
    var modifiedAt: Double = nowMillis()
    /// Nur lokal: noch nicht zum Server übertragen.
    var dirty: Bool = true

    enum CodingKeys: String, CodingKey {
        case id, folderId, text, blocks, pinned, trashed, deleted, createdAt, modifiedAt, dirty
    }

    /// Blöcke der Notiz; ältere Notizen ohne Blöcke werden als ein Textblock gezeigt.
    var content: [NoteBlock] {
        if let blocks { return blocks }
        return [NoteBlock(id: "legacy-\(id)", kind: .text, text: text)]
    }

    static func plainText(of blocks: [NoteBlock]) -> String {
        blocks.filter { $0.kind == .text }.compactMap(\.text)
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    var blobRefs: [String] { (blocks ?? []).flatMap(\.blobRefs) }

    /// Papier für Handschrift: "blank", "lined" oder "grid".
    var paper: String { (blocks ?? []).compactMap(\.paper).first ?? "blank" }

    private var lines: [Substring] {
        text.split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private static func clean(_ line: Substring) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        for prefix in ["### ", "## ", "# ", "- [ ] ", "- [x] ", "- [X] ", "- ", "* "] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
            break
        }
        // Markdown-Zeichen in Titel und Vorschau ausblenden.
        for mark in ["**", "__", "`", "$$", "$"] {
            s = s.replacingOccurrences(of: mark, with: "")
        }
        return s
    }

    private var attachmentSummary: String? {
        let blocks = content
        if let f = blocks.first(where: { $0.kind == .file })?.file { return f.name }
        if blocks.contains(where: { $0.background?.kind == .pdf }) { return "PDF" }
        if blocks.contains(where: { $0.background?.kind == .image }) { return "Bild" }
        if blocks.contains(where: { $0.kind == .canvas && ($0.hasInk || !($0.images ?? []).isEmpty) }) {
            return "Handschriftliche Notiz"
        }
        return nil
    }

    /// Erkannter Text aus Handschrift, Fotos und PDFs.
    var recognizedText: String {
        content.compactMap(\.recognized).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Erkannte Handschrift (ohne Fotos/PDFs) – taugt als Titel.
    private var inkLines: [Substring] {
        content.filter(\.isInk).compactMap(\.recognized).joined(separator: "\n")
            .split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var title: String {
        if let first = lines.first { return Self.clean(first) }
        if let first = inkLines.first { return Self.clean(first) }
        return attachmentSummary ?? "Neue Notiz"
    }

    var preview: String {
        if isLocked { return "Gesperrt" }
        let l = lines
        if l.count > 1 { return Self.clean(l[1]) }
        if l.isEmpty {
            let ink = inkLines
            if ink.count > 1 { return Self.clean(ink[1]) }
        }
        if let a = attachmentSummary, a != title { return a }
        return "Kein weiterer Text"
    }

    var isBlank: Bool {
        content.allSatisfy(\.isEmpty)
    }

    func matches(_ query: String) -> Bool {
        text.localizedCaseInsensitiveContains(query)
            || content.contains { $0.file?.name.localizedCaseInsensitiveContains(query) == true }
            || content.contains { $0.recognized?.localizedCaseInsensitiveContains(query) == true }
    }

    var modifiedDate: Date { Date(timeIntervalSince1970: modifiedAt / 1000) }
    var createdDate: Date { Date(timeIntervalSince1970: createdAt / 1000) }

    /// Tags aus getipptem und erkanntem Text, ohne Groß-/Kleinschreibung doppelt.
    var tags: [String] {
        var seen = Set<String>()
        return Tags.find(in: text + "\n" + recognizedText).filter { seen.insert($0.lowercased()).inserted }
    }

    func hasTag(_ tag: String) -> Bool {
        tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }
}

extension Note {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        folderId = try c.decodeIfPresent(String.self, forKey: .folderId)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        blocks = try c.decodeIfPresent([NoteBlock].self, forKey: .blocks)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        trashed = try c.decodeIfPresent(Bool.self, forKey: .trashed) ?? false
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        modifiedAt = try c.decode(Double.self, forKey: .modifiedAt)
        createdAt = try c.decodeIfPresent(Double.self, forKey: .createdAt) ?? modifiedAt
        dirty = try c.decodeIfPresent(Bool.self, forKey: .dirty) ?? false
    }
}

struct Folder: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String = ""
    var deleted: Bool = false
    var modifiedAt: Double = nowMillis()
    var dirty: Bool = true

    enum CodingKeys: String, CodingKey {
        case id, name, deleted, modifiedAt, dirty
    }
}

extension Folder {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        modifiedAt = try c.decode(Double.self, forKey: .modifiedAt)
        dirty = try c.decodeIfPresent(Bool.self, forKey: .dirty) ?? false
    }
}

enum SidebarItem: Hashable {
    case all
    case folder(String)
    case tag(String)
    case trash
}

/// Sortierung der Notizliste.
enum NoteSort: String, CaseIterable, Identifiable {
    case modified, created, title
    var id: String { rawValue }
    var label: String {
        switch self {
        case .modified: return "Zuletzt bearbeitet"
        case .created: return "Erstellt"
        case .title: return "Titel"
        }
    }
}

enum Tags {
    /// `#Wort` – nicht nach Buchstaben/Ziffern (also keine Überschriften `# `, keine `##`).
    static let regex = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_#&/])#([\p{L}\p{N}][\p{L}\p{N}_\-]*)"#)

    static func find(in text: String) -> [String] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1))
        }
    }
}

enum SyncState: Equatable {
    case notConfigured
    case syncing
    case idle(Date)
    case error(String)
}
