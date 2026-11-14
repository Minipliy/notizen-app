import SwiftUI

/// Zeigt Text mit einfachem Markdown, Checklisten und LaTeX-Formeln an.
///
/// Unterstützt: `# Überschrift`, `- Aufzählung`, `1. Liste`, `- [ ] Aufgabe`, `**fett**`, `*kursiv*`,
/// `` `Code` ``, Codeblöcke mit ``` ``` ```, `$Formel$` im Text und `$$Formel$$` abgesetzt.
struct RichTextView: View {
    let text: String
    /// Wird mit der Zeilennummer aufgerufen, wenn eine Checkbox angetippt wird.
    var onToggleCheckbox: ((Int) -> Void)? = nil

    @Environment(\.colorScheme) private var scheme

    enum Element: Identifiable {
        case heading(Int, String, Int)
        case checkbox(Bool, String, Int)
        case bullet(String, Int)
        case numbered(String, String, Int)
        case paragraph(String, Int)
        case displayMath(String, Int)
        case code(String, Int)
        case table([[String]], Int)
        case spacer(Int)

        var id: Int {
            switch self {
            case .heading(_, _, let i), .checkbox(_, _, let i), .bullet(_, let i), .numbered(_, _, let i),
                 .paragraph(_, let i), .displayMath(_, let i), .code(_, let i), .table(_, let i), .spacer(let i):
                return i
            }
        }
    }

    static func parse(_ text: String) -> [Element] {
        let lines = text.components(separatedBy: "\n")
        var out: [Element] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)

            if t.hasPrefix("```") {
                var body: [String] = []
                let start = i
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[i])
                    i += 1
                }
                out.append(.code(body.joined(separator: "\n"), start))
                i += 1
                continue
            }

            if t.hasPrefix("$$") {
                let start = i
                var body = String(t.dropFirst(2))
                if body.hasSuffix("$$"), body.count >= 2 {
                    body = String(body.dropLast(2))
                } else {
                    i += 1
                    var parts = [body]
                    while i < lines.count {
                        let l = lines[i].trimmingCharacters(in: .whitespaces)
                        if l.hasSuffix("$$") {
                            parts.append(String(l.dropLast(2)))
                            break
                        }
                        parts.append(lines[i])
                        i += 1
                    }
                    body = parts.joined(separator: " ")
                }
                out.append(.displayMath(body.trimmingCharacters(in: .whitespaces), start))
                i += 1
                continue
            }

            if t.hasPrefix("|") {
                // Tabelle: aufeinanderfolgende Zeilen mit | … |, Trennzeile |---| wird übersprungen.
                let start = i
                var rows: [[String]] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    var row = lines[i].trimmingCharacters(in: .whitespaces)
                    row.removeFirst()
                    if row.hasSuffix("|") { row.removeLast() }
                    let cells = row.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                    let isSeparator = cells.allSatisfy { !$0.isEmpty && $0.allSatisfy { "-: ".contains($0) } }
                    if !isSeparator { rows.append(cells) }
                    i += 1
                }
                out.append(.table(rows, start))
                continue
            }

            if t.isEmpty {
                out.append(.spacer(i))
            } else if let level = ["### ": 3, "## ": 2, "# ": 1].first(where: { t.hasPrefix($0.key) }) {
                out.append(.heading(level.value, String(t.dropFirst(level.key.count)), i))
            } else if t.hasPrefix("- [ ] ") || t.hasPrefix("* [ ] ") {
                out.append(.checkbox(false, String(t.dropFirst(6)), i))
            } else if t.hasPrefix("- [x] ") || t.hasPrefix("- [X] ") || t.hasPrefix("* [x] ") {
                out.append(.checkbox(true, String(t.dropFirst(6)), i))
            } else if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("• ") {
                out.append(.bullet(String(t.dropFirst(2)), i))
            } else if let r = t.range(of: #"^\d+[.)] "#, options: .regularExpression) {
                out.append(.numbered(String(t[r]).trimmingCharacters(in: .whitespaces), String(t[r.upperBound...]), i))
            } else {
                out.append(.paragraph(line, i))
            }
            i += 1
        }
        return out
    }

    /// Schaltet die Checkbox in Zeile `line` um und gibt den neuen Text zurück.
    static func toggleCheckbox(in text: String, line: Int) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(line) else { return text }
        let l = lines[line]
        for (a, b) in [("[ ]", "[x]"), ("[x]", "[ ]"), ("[X]", "[ ]")] {
            if let r = l.range(of: a) {
                lines[line] = l.replacingCharacters(in: r, with: b)
                break
            }
        }
        return lines.joined(separator: "\n")
    }

    #if os(macOS)
    private let baseSize: CGFloat = 13
    #else
    private let baseSize: CGFloat = 17
    #endif

    var body: some View {
        let math = MathEval.results(for: text)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Self.parse(text)) { element in
                view(for: element, math: math)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Ergebnis einer Rechenzeile in Akzentfarbe anhängen.
    private func withResult(_ t: Text, _ line: Int, _ math: [Int: String]) -> Text {
        guard let r = math[line] else { return t }
        return t + Text(" " + r).foregroundColor(.notesAccent).bold()
    }

    private func tableView(_ rows: [[String]]) -> some View {
        let columns = rows.map(\.count).max() ?? 0
        return ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(rows.indices, id: \.self) { r in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { c in
                            let cell = c < rows[r].count ? rows[r][c] : ""
                            inline(cell, size: baseSize)
                                .fontWeight(r == 0 ? .semibold : .regular)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)
                                .background(r == 0 ? Color.secondary.opacity(0.12) : Color.clear)
                                .overlay(Rectangle().stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.35), lineWidth: 0.5))
        }
    }

    @ViewBuilder
    private func view(for element: Element, math: [Int: String]) -> some View {
        switch element {
        case .heading(let level, let s, _):
            inline(s, size: [1: baseSize * 1.6, 2: baseSize * 1.35, 3: baseSize * 1.15][level] ?? baseSize)
                .font(level == 1 ? .title.bold() : level == 2 ? .title2.bold() : .title3.bold())
                .padding(.top, 4)
        case .checkbox(let done, let s, let line):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    onToggleCheckbox?(line)
                } label: {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(done ? Color.notesAccent : .secondary)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                inline(s, size: baseSize)
                    .strikethrough(done)
                    .foregroundStyle(done ? .secondary : .primary)
            }
        case .bullet(let s, let line):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(Color.notesAccent)
                withResult(inline(s, size: baseSize), line, math)
            }
        case .numbered(let n, let s, _):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(n).monospacedDigit().foregroundStyle(.secondary)
                inline(s, size: baseSize)
            }
        case .paragraph(let s, let line):
            withResult(inline(s, size: baseSize), line, math)
        case .table(let rows, _):
            tableView(rows)
        case .displayMath(let latex, _):
            DisplayMathView(latex: latex)
        case .code(let s, _):
            Text(s)
                .font(.callout.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        case .spacer:
            Color.clear.frame(height: baseSize * 0.5)
        }
    }

    /// Fließtext mit Markdown und eingebetteten Formeln (`$…$`).
    private func inline(_ s: String, size: CGFloat) -> Text {
        var result = Text("")
        var rest = Substring(s)
        while let open = Self.findDollar(in: rest) {
            let afterOpen = rest.index(after: open)
            guard let close = Self.findDollar(in: rest[afterOpen...]), close > afterOpen else { break }
            result = result + markdown(String(rest[..<open]))
            let latex = String(rest[afterOpen..<close])
            if let r = MathRenderer.render(latex, fontSize: size, dark: scheme == .dark) {
                result = result + Text(Image(platformImage: r.image)).baselineOffset(-r.descent)
            } else {
                result = result + Text("$\(latex)$").foregroundColor(.red)
            }
            rest = rest[rest.index(after: close)...]
        }
        return result + markdown(String(rest))
    }

    /// Findet ein `$`, das nicht mit `\` maskiert ist.
    private static func findDollar(in s: Substring) -> Substring.Index? {
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "\\" {
                i = s.index(after: i)
                if i < s.endIndex { i = s.index(after: i) }
                continue
            }
            if s[i] == "$" { return i }
            i = s.index(after: i)
        }
        return nil
    }

    private func markdown(_ s: String) -> Text {
        guard !s.isEmpty else { return Text("") }
        var unescaped = s.replacingOccurrences(of: "\\$", with: "$")
        // [[Titel]] → Link zu einer anderen Notiz.
        if unescaped.contains("[[") {
            let regex = try! NSRegularExpression(pattern: #"\[\[([^\[\]\n]+)\]\]"#)
            let ns = unescaped as NSString
            var result = ""
            var last = 0
            for m in regex.matches(in: unescaped, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let title = ns.substring(with: m.range(at: 1))
                let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
                result += "[\(title)](notizen://note/\(encoded))"
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            unescaped = result
        }
        if var attr = try? AttributedString(
            markdown: unescaped,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            // #Tags in der Akzentfarbe.
            for tag in Tags.find(in: String(attr.characters)) {
                var searchStart = attr.startIndex
                while let r = attr[searchStart...].range(of: "#" + tag) {
                    attr[r].foregroundColor = .notesAccent
                    searchStart = r.upperBound
                }
            }
            return Text(attr)
        }
        return Text(unescaped)
    }
}
