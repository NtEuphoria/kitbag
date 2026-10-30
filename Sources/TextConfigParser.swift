// Text config (config.cpp after preprocessing) → ConfigClass tree.
import Foundation

/// Where and why a text config could not be parsed.
struct TextConfigError: Error, CustomStringConvertible {
    let message: String
    let line: Int
    var description: String { "line \(line): \(message)" }
}

/// Parser for preprocessed Arma config text, tolerant in the ways the game is:
/// missing `;` after values and class bodies, stray `;`, unquoted words as strings,
/// single- or double-quoted strings (doubled quote = literal quote), `key = {…}` without `[]`, `enum {…};`.
/// `__EVAL(…)` is kept verbatim as a string and `__EXEC(…)` is skipped (both need the engine).
/// A class defined twice in one scope is merged, as the game merges config updates.
/// Like the binarizer, numbers with a fraction or exponent are rounded to float32, so a `config.cpp` and its
/// `config.bin` agree. `db+N` sound volumes stay strings as written (binarizers differ on converting them).
enum TextConfigParser {
    static func parse(_ text: String) throws -> ConfigClass {
        var p = Parser(s: Array(text.utf8))
        let root = ConfigClass(name: "")
        try p.body(root, closed: false)
        return root
    }
}

private let SEMI: UInt8 = 0x3B, LBRACE: UInt8 = 0x7B, RBRACE: UInt8 = 0x7D, COLON: UInt8 = 0x3A
private let EQ: UInt8 = 0x3D, LBRACK: UInt8 = 0x5B, RBRACK: UInt8 = 0x5D, PLUS: UInt8 = 0x2B
private let DQ: UInt8 = 0x22, SQ: UInt8 = 0x27, COMMA_: UInt8 = 0x2C, LPAREN: UInt8 = 0x28, RPAREN: UInt8 = 0x29
private let NEWLINE: UInt8 = 0x0A

private struct Parser {
    let s: [UInt8]
    var i = 0
    /// Children by lowercased name for every class touched, so reopened classes merge in O(1).
    var index: [ObjectIdentifier: [String: ConfigClass]] = [:]

    init(s: [UInt8]) { self.s = s }

    func fail(_ message: String, at pos: Int? = nil) -> TextConfigError {
        let end = min(pos ?? i, s.count)
        return TextConfigError(message: message, line: 1 + s[0..<end].reduce(0) { $0 + ($1 == NEWLINE ? 1 : 0) })
    }

    var peek: UInt8? { i < s.count ? s[i] : nil }

    mutating func skipSpace() { while i < s.count && s[i] <= 0x20 { i += 1 } }

    /// Spaces and tabs only, so a value can end at a line break.
    mutating func skipBlanks() { while i < s.count && (s[i] == 0x20 || s[i] == 0x09 || s[i] == 0x0D) { i += 1 } }

    static func isNameByte(_ c: UInt8) -> Bool {
        switch c {
        case 0...0x20, SEMI, LBRACE, RBRACE, COLON, EQ, LBRACK, RBRACK, PLUS, DQ, SQ, COMMA_, LPAREN, RPAREN: return false
        default: return true
        }
    }

    mutating func name() -> String? {
        let start = i
        while i < s.count && Parser.isNameByte(s[i]) { i += 1 }
        return i > start ? String(decoding: s[start..<i], as: UTF8.self) : nil
    }

    mutating func expectName(_ what: String) throws -> String {
        skipSpace()
        guard let n = name() else { throw fail("expected \(what)") }
        return n
    }

    mutating func eat(_ c: UInt8) -> Bool {
        skipSpace()
        if peek == c { i += 1; return true }
        return false
    }

    /// Statements until `}` (when `closed`) or end of input.
    mutating func body(_ cls: ConfigClass, closed: Bool) throws {
        let openedAt = i
        while true {
            skipSpace()
            guard let c = peek else {
                if closed { throw fail("missing '}' for class \(cls.name)", at: openedAt) }
                return
            }
            if c == SEMI { i += 1; continue }
            if c == RBRACE {
                guard closed else { throw fail("unexpected '}'") }
                i += 1
                return
            }
            let start = i
            guard let word = name() else { throw fail("unexpected '\(String(decoding: [c], as: UTF8.self))'") }
            switch word {
            case "class":
                try classStatement(in: cls)
            case "delete":
                cls.deletes.append(try expectName("class name after delete"))
                _ = eat(SEMI)
            case "enum":   // `enum { a = 1, b, … };` names engine constants; nothing to keep
                skipSpace()
                guard peek == LBRACE else { i = start; try property(in: cls); continue }
                i += 1
                _ = try arrayItems()
            case "__EXEC":
                skipSpace()
                guard peek == LPAREN else { throw fail("expected '(' after __EXEC") }
                _ = try balanced()
            default:
                i = start
                try property(in: cls)
            }
        }
    }

    mutating func classStatement(in parent: ConfigClass) throws {
        let name = try expectName("class name")
        var base: String?
        if eat(COLON) { base = try expectName("base class name") }
        skipSpace()
        let cls = child(of: parent, name)
        if eat(LBRACE) {
            cls.isExternal = false
            if let base { cls.parent = base }
            try body(cls, closed: true)
        } else {
            // `class X;` (or the tolerated `class X: Y;`): a reference to an existing class.
            if cls.parent == nil, let base { cls.parent = base }
            guard peek == SEMI || peek == RBRACE || peek == nil else { throw fail("expected '{' or ';' after class \(name)") }
        }
    }

    /// Existing child of that name (reopened class) or a new external one.
    mutating func child(of parent: ConfigClass, _ name: String) -> ConfigClass {
        let id = ObjectIdentifier(parent), key = name.lowercased()
        if let c = index[id]?[key] { return c }
        let c = ConfigClass(name: name, isExternal: true)
        parent.children.append(c)
        index[id, default: [:]][key] = c
        return c
    }

    mutating func property(in cls: ConfigClass) throws {
        let key = try expectName("property name").lowercased()
        if eat(LBRACK), !eat(RBRACK) { throw fail("expected ']' after \(key)[") }
        skipSpace()
        var append = false
        if peek == PLUS, i + 1 < s.count, s[i + 1] == EQ { append = true; i += 2 }
        else if peek == EQ { i += 1 }
        else { throw fail("expected '=' after \(key)") }
        skipSpace()
        if peek == LBRACE {
            i += 1
            let items = try arrayItems()
            if append { cls.appends[key, default: []].append(contentsOf: items) } else { cls.properties[key] = .array(items) }
        } else {
            let v = try scalar(inArray: false)
            if append { cls.appends[key, default: []].append(v) } else { cls.properties[key] = v }
        }
        endStatement()
    }

    /// After a value: `;`, or tolerated end of line / `}` / anything up to the next `;` on the same line.
    mutating func endStatement() {
        skipBlanks()
        guard let c = peek else { return }
        if c == SEMI { i += 1; return }
        if c == NEWLINE || c == RBRACE { return }
        while i < s.count && s[i] != SEMI && s[i] != NEWLINE && s[i] != RBRACE { i += 1 }
        if peek == SEMI { i += 1 }
    }

    /// Elements after `{` up to the matching `}`.
    mutating func arrayItems() throws -> [ConfigValue] {
        let openedAt = i - 1
        var items: [ConfigValue] = []
        while true {
            skipSpace()
            guard let c = peek else { throw fail("missing '}' for array", at: openedAt) }
            if c == RBRACE { i += 1; return items }
            if c == COMMA_ { i += 1; continue }   // separators, including trailing or doubled commas
            if c == LBRACE { i += 1; items.append(.array(try arrayItems())); continue }
            let before = i
            items.append(try scalar(inArray: true))
            // A `;` inside braces ends the element without consuming anything; the game rejects it as well.
            if i == before { throw fail("unexpected '\(String(decoding: [c], as: UTF8.self))' in array") }
        }
    }

    /// A string, number, `__EVAL(…)` or unquoted word run.
    mutating func scalar(inArray: Bool) throws -> ConfigValue {
        guard let c = peek else { throw fail("missing value") }
        if c == DQ || c == SQ { return .string(try quoted(c)) }
        let start = i
        if let w = name(), w == "__EVAL" {
            skipBlanks()
            if peek == LPAREN {
                let inner = try balanced()
                return .string("__EVAL" + inner)
            }
        }
        i = start
        // Unquoted: up to the end of the statement (or element), trailing blanks trimmed.
        while i < s.count {
            let b = s[i]
            if b == SEMI || b == RBRACE || (b == NEWLINE && !inArray) || (inArray && b == COMMA_) { break }
            if inArray && b == LBRACE { break }
            i += 1
        }
        var end = i
        while end > start && s[end - 1] <= 0x20 { end -= 1 }
        let raw = String(decoding: s[start..<end], as: UTF8.self)
        if let n = Parser.number(raw) { return .number(n) }
        return .string(raw)
    }

    /// Quoted string starting at `i`; a doubled quote stands for one quote character.
    mutating func quoted(_ q: UInt8) throws -> String {
        let openedAt = i
        i += 1
        var out = [UInt8]()
        while true {
            guard i < s.count else { throw fail("unterminated string", at: openedAt) }
            let b = s[i]
            i += 1
            if b == q {
                if peek == q { out.append(q); i += 1; continue }
                return String(decoding: out, as: UTF8.self)
            }
            out.append(b)
        }
    }

    /// `( … )` starting at `i`, nesting and quotes respected; returns it including the parentheses.
    mutating func balanced() throws -> String {
        let start = i, openedAt = i
        var depth = 0
        while i < s.count {
            let b = s[i]
            if b == DQ || b == SQ { _ = try quoted(b); continue }
            i += 1
            if b == LPAREN { depth += 1 }
            else if b == RPAREN { depth -= 1; if depth == 0 { return String(decoding: s[start..<i], as: UTF8.self) } }
        }
        throw fail("missing ')'", at: openedAt)
    }

    /// Decimal (optionally signed, fractional, exponent) or `0x` hex. Anything else is a string.
    /// Integer literals stay exact; anything with a fraction or exponent is rounded to float32 like the engine does.
    static func number(_ t: String) -> Double? {
        let b = Array(t.utf8)
        guard !b.isEmpty else { return nil }
        var j = 0
        if b[j] == 0x2D || b[j] == 0x2B { j += 1 }
        if j + 1 < b.count, b[j] == 0x30, b[j + 1] | 0x20 == 0x78 {
            let hex = String(decoding: b[(j + 2)...], as: UTF8.self)
            guard !hex.isEmpty, let v = UInt64(hex, radix: 16) else { return nil }
            return b[0] == 0x2D ? -Double(v) : Double(v)
        }
        var digits = 0, k = j
        while k < b.count && b[k] >= 0x30 && b[k] <= 0x39 { k += 1; digits += 1 }
        if k < b.count && b[k] == 0x2E { k += 1; while k < b.count && b[k] >= 0x30 && b[k] <= 0x39 { k += 1; digits += 1 } }
        guard digits > 0 else { return nil }
        if k < b.count && b[k] | 0x20 == 0x65 {
            k += 1
            if k < b.count && (b[k] == 0x2D || b[k] == 0x2B) { k += 1 }
            let e = k
            while k < b.count && b[k] >= 0x30 && b[k] <= 0x39 { k += 1 }
            guard k > e else { return nil }
        }
        guard k == b.count else { return nil }
        guard let d = Double(t) else { return nil }
        let integral = !b.contains(0x2E) && !b.contains(where: { $0 | 0x20 == 0x65 })
        return integral || !Float(d).isFinite ? d : Double(Float(d).description)
    }
}
