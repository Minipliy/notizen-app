import SwiftUI

/// Formatierungen für Textblöcke (Markdown), angewendet auf Text und Auswahl.
enum TextFormat {
    case checklist, bullet, numbered, heading, bold, italic, math, table

    var label: String {
        switch self {
        case .checklist: return "Checkliste"
        case .bullet: return "Aufzählung"
        case .numbered: return "Nummerierung"
        case .heading: return "Überschrift"
        case .bold: return "Fett"
        case .italic: return "Kursiv"
        case .math: return "Formel"
        case .table: return "Tabelle"
        }
    }

    var icon: String {
        switch self {
        case .checklist: return "checklist"
        case .bullet: return "list.bullet"
        case .numbered: return "list.number"
        case .heading: return "textformat.size"
        case .bold: return "bold"
        case .italic: return "italic"
        case .math: return "function"
        case .table: return "tablecells"
        }
    }

    /// Wendet die Formatierung an; Auswahl als Zeichen-Offsets, Rückgabe neuer Text und neue Auswahl.
    func apply(to text: String, selection: Range<Int>) -> (String, Range<Int>) {
        switch self {
        case .checklist: return Self.toggleLinePrefix(text, selection, prefixes: ["- [ ] ", "- [x] ", "- [X] "], add: "- [ ] ")
        case .bullet: return Self.toggleLinePrefix(text, selection, prefixes: ["- ", "• "], add: "- ")
        case .numbered: return Self.toggleNumbered(text, selection)
        case .heading: return Self.cycleHeading(text, selection)
        case .bold: return Self.wrap(text, selection, "**")
        case .italic: return Self.wrap(text, selection, "*")
        case .math: return Self.wrap(text, selection, "$")
        case .table: return Self.insertTable(text, selection)
        }
    }

    // MARK: - Zeilen

    private static func lineRanges(_ text: String) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        for (i, ch) in text.enumerated() where ch == "\n" {
            ranges.append(start..<i)
            start = i + 1
        }
        ranges.append(start..<text.count)
        return ranges
    }

    /// Zeilen, die die Auswahl berührt.
    private static func touchedLines(_ text: String, _ sel: Range<Int>) -> [Int] {
        let lines = lineRanges(text)
        return lines.indices.filter { i in
            let r = lines[i]
            return (r.lowerBound <= sel.upperBound && sel.lowerBound <= r.upperBound)
        }
    }

    private static func rebuild(_ text: String, editing lineIDs: [Int], sel: Range<Int>,
                                _ transform: (Int, String) -> String) -> (String, Range<Int>) {
        var lines = text.components(separatedBy: "\n")
        var delta = 0, deltaBefore = 0
        let ranges = lineRanges(text)
        for i in lineIDs where lines.indices.contains(i) {
            let old = lines[i]
            let new = transform(i, old)
            let d = new.count - old.count
            if ranges[i].lowerBound <= sel.lowerBound { deltaBefore += d }
            delta += d
            lines[i] = new
        }
        let lower = max(0, sel.lowerBound + deltaBefore)
        let upper = max(lower, sel.upperBound + delta)
        return (lines.joined(separator: "\n"), lower..<upper)
    }

    private static func toggleLinePrefix(_ text: String, _ sel: Range<Int>, prefixes: [String], add: String)
        -> (String, Range<Int>) {
        let ids = touchedLines(text, sel)
        let lines = text.components(separatedBy: "\n")
        // Haben alle Zeilen die Markierung schon, wird sie entfernt, sonst gesetzt.
        let allHave = ids.allSatisfy { i in prefixes.contains { lines[i].hasPrefix($0) } }
        return rebuild(text, editing: ids, sel: sel) { _, line in
            var stripped = line
            for p in prefixes + ["- [ ] ", "- [x] ", "- ", "• "] where stripped.hasPrefix(p) {
                stripped = String(stripped.dropFirst(p.count))
                break
            }
            if let r = stripped.range(of: #"^\d+[.)] "#, options: .regularExpression) {
                stripped.removeSubrange(r)
            }
            return allHave ? stripped : add + stripped
        }
    }

    private static func toggleNumbered(_ text: String, _ sel: Range<Int>) -> (String, Range<Int>) {
        let ids = touchedLines(text, sel)
        let lines = text.components(separatedBy: "\n")
        let pattern = #"^\d+[.)] "#
        let allHave = ids.allSatisfy { lines[$0].range(of: pattern, options: .regularExpression) != nil }
        var n = 0
        return rebuild(text, editing: ids, sel: sel) { _, line in
            var stripped = line
            if let r = stripped.range(of: pattern, options: .regularExpression) { stripped.removeSubrange(r) }
            for p in ["- [ ] ", "- [x] ", "- ", "• "] where stripped.hasPrefix(p) {
                stripped = String(stripped.dropFirst(p.count))
                break
            }
            n += 1
            return allHave ? stripped : "\(n). " + stripped
        }
    }

    /// Normal → # → ## → ### → normal.
    private static func cycleHeading(_ text: String, _ sel: Range<Int>) -> (String, Range<Int>) {
        let ids = touchedLines(text, sel)
        return rebuild(text, editing: ids, sel: sel) { _, line in
            if line.hasPrefix("### ") { return String(line.dropFirst(4)) }
            if line.hasPrefix("## ") { return "#" + line }
            if line.hasPrefix("# ") { return "#" + line }
            return "# " + line
        }
    }

    /// Leere Tabelle (3 Spalten, 2 Zeilen) in einer neuen Zeile einfügen.
    private static func insertTable(_ text: String, _ sel: Range<Int>) -> (String, Range<Int>) {
        let chars = Array(text)
        let at = min(sel.upperBound, chars.count)
        // Bis zum Zeilenende gehen, damit die Tabelle in eigenen Zeilen steht.
        var end = at
        while end < chars.count, chars[end] != "\n" { end += 1 }
        let before = String(chars[..<end])
        let needsBreak = !before.isEmpty && !before.hasSuffix("\n")
        let table = (needsBreak ? "\n" : "") + "| Spalte 1 | Spalte 2 | Spalte 3 |\n| --- | --- | --- |\n|  |  |  |\n|  |  |  |"
        let new = before + table + String(chars[end...])
        let cursor = before.count + (needsBreak ? 1 : 0) + 2
        return (new, cursor..<(cursor + 8))
    }

    // MARK: - Auswahl umschließen

    private static func wrap(_ text: String, _ sel: Range<Int>, _ mark: String) -> (String, Range<Int>) {
        let chars = Array(text)
        let lower = min(sel.lowerBound, chars.count), upper = min(sel.upperBound, chars.count)
        let selected = String(chars[lower..<upper])
        let m = mark.count
        // Schon umschlossen → Markierung entfernen.
        if lower >= m, upper + m <= chars.count,
           String(chars[(lower - m)..<lower]) == mark, String(chars[upper..<(upper + m)]) == mark {
            let new = String(chars[..<(lower - m)]) + selected + String(chars[(upper + m)...])
            return (new, (lower - m)..<(upper - m))
        }
        let new = String(chars[..<lower]) + mark + selected + mark + String(chars[upper...])
        return (new, (lower + m)..<(upper + m))
    }
}

/// Leiste mit Formatierknöpfen über dem Textblock, der gerade bearbeitet wird.
struct FormatBar: View {
    let onFormat: (TextFormat) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach([TextFormat.checklist, .bullet, .numbered, .heading, .bold, .italic, .math, .table], id: \.label) { f in
                    Button {
                        onFormat(f)
                    } label: {
                        Image(systemName: f.icon)
                            .frame(width: 34, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help(f.label)
                    .accessibilityLabel(f.label)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
        }
        .background(.regularMaterial, in: Capsule())
        .fixedSize(horizontal: false, vertical: true)
    }
}
