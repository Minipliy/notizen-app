import Foundation

/// Rechnet einfache Ausdrücke aus, wie in den „Mathe-Notizen“ von Apple:
/// `12 * 3,5 =` zeigt das Ergebnis, `Miete = 650` legt eine Variable an.
enum MathEval {
    /// Ergebnisse je Zeilennummer für Zeilen, die mit `=` enden.
    static func results(for text: String) -> [Int: String] {
        var vars: [String: Double] = [:]
        var out: [Int: String] = [:]
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            var line = raw.trimmingCharacters(in: .whitespaces)
            for prefix in ["- [ ] ", "- [x] ", "- ", "* ", "• "] where line.hasPrefix(prefix) {
                line = String(line.dropFirst(prefix.count))
            }
            guard !line.isEmpty, !line.contains("$") else { continue }
            if line.hasSuffix("=") {
                let expr = String(line.dropLast())
                // „Summe = a + b =“ → rechte Seite rechnen und als Variable merken.
                var parts = expr.components(separatedBy: "=")
                // „Pro Woche: 738 / 4 =“ – Beschriftung vor „: “ ignorieren.
                if parts.count == 1, let r = expr.range(of: ": "), evaluate(expr, vars: vars) == nil {
                    parts = [String(expr[r.upperBound...])]
                }
                let rhs = parts.last ?? expr
                if let v = evaluate(rhs, vars: vars), containsOperatorOrVariable(rhs, vars: vars) {
                    out[i] = format(v)
                    if parts.count == 2, let name = variableName(parts[0]) { vars[name] = v }
                }
            } else if let eq = line.firstIndex(of: "="), line.filter({ $0 == "=" }).count == 1 {
                // Variable: „Name = Ausdruck“
                if let name = variableName(String(line[..<eq])),
                   let v = evaluate(String(line[line.index(after: eq)...]), vars: vars) {
                    vars[name] = v
                }
            }
        }
        return out
    }

    private static func variableName(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 30,
              t.range(of: #"^[\p{L}_][\p{L}\p{N}_ ]*$"#, options: .regularExpression) != nil else { return nil }
        return t.lowercased()
    }

    private static func containsOperatorOrVariable(_ s: String, vars: [String: Double]) -> Bool {
        s.contains { "+-*/×÷^%()·:".contains($0) } || s.contains(where: \.isLetter)
    }

    static func format(_ v: Double) -> String {
        guard v.isFinite else { return "–" }
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.numberStyle = .decimal
        f.maximumFractionDigits = abs(v) < 1 ? 6 : 4
        f.usesGroupingSeparator = abs(v) >= 10_000
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }

    // MARK: - Parser (rekursiver Abstieg, ohne NSExpression – stürzt bei Unsinn nicht ab)

    static func evaluate(_ input: String, vars: [String: Double] = [:]) -> Double? {
        var p = Parser(text: input, vars: vars)
        guard let v = p.expression(), p.atEnd else { return nil }
        return v
    }

    private struct Parser {
        let chars: [Character]
        let vars: [String: Double]
        var i = 0

        init(text: String, vars: [String: Double]) {
            chars = Array(text)
            self.vars = vars
        }

        var atEnd: Bool {
            var j = i
            while j < chars.count, chars[j] == " " { j += 1 }
            return j >= chars.count
        }

        mutating func skip() { while i < chars.count, chars[i] == " " { i += 1 } }

        mutating func peek() -> Character? {
            skip()
            return i < chars.count ? chars[i] : nil
        }

        mutating func expression() -> Double? {
            guard var v = term() else { return nil }
            while let c = peek(), c == "+" || c == "-" || c == "−" {
                i += 1
                guard let r = term() else { return nil }
                v = c == "+" ? v + r : v - r
            }
            return v
        }

        mutating func term() -> Double? {
            guard var v = power() else { return nil }
            while let c = peek(), "*/×÷·:".contains(c) {
                i += 1
                guard let r = power() else { return nil }
                v = (c == "/" || c == "÷" || c == ":") ? v / r : v * r
            }
            return v
        }

        mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if peek() == "^" {
                i += 1
                guard let e = power() else { return nil }
                return pow(base, e)
            }
            return base
        }

        mutating func unary() -> Double? {
            if let c = peek(), c == "-" || c == "−" {
                i += 1
                return unary().map { -$0 }
            }
            if peek() == "+" { i += 1 }
            guard var v = primary() else { return nil }
            if peek() == "%" {
                i += 1
                v /= 100
            }
            return v
        }

        mutating func primary() -> Double? {
            guard let c = peek() else { return nil }
            if c == "(" {
                i += 1
                let v = expression()
                guard peek() == ")" else { return nil }
                i += 1
                return v
            }
            if c.isNumber {
                var s = ""
                while i < chars.count, chars[i].isNumber || chars[i] == "," || chars[i] == "." {
                    s.append(chars[i])
                    i += 1
                }
                // Deutsch: Komma = Dezimaltrennzeichen, Punkt = Tausender (1.000,5)
                if s.contains(",") {
                    s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
                } else if s.filter({ $0 == "." }).count > 1 {
                    s = s.replacingOccurrences(of: ".", with: "")
                }
                return Double(s)
            }
            if c.isLetter || c == "√" || c == "π" {
                if c == "√" {
                    i += 1
                    return primary().map(sqrt)
                }
                if c == "π" {
                    i += 1
                    return .pi
                }
                var name = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" || chars[i] == " " {
                    // Leerzeichen nur innerhalb mehrteiliger Variablennamen
                    if chars[i] == " " {
                        let rest = String(chars[i...]).trimmingCharacters(in: .whitespaces)
                        let candidate = (name + " " + rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }).lowercased()
                        if vars.keys.contains(where: { $0.hasPrefix(candidate) }) {
                            name.append(" ")
                            i += 1
                            continue
                        }
                        break
                    }
                    name.append(chars[i])
                    i += 1
                }
                let key = name.trimmingCharacters(in: .whitespaces).lowercased()
                let fns: [String: (Double) -> Double] = [
                    "sqrt": sqrt, "wurzel": sqrt, "sin": sin, "cos": cos, "tan": tan,
                    "ln": log, "log": log10, "abs": abs, "exp": exp,
                ]
                if let f = fns[key], peek() == "(" {
                    return primary().map(f)
                }
                if key == "pi" { return .pi }
                if key == "e" { return M_E }
                return vars[key]
            }
            return nil
        }
    }
}
