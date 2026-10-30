// Text-config preprocessing: the game's virtual file system (for #include and
// __has_include) and a preprocessor that follows Arma 3's macro rules.
import Foundation

// MARK: - Virtual file system

/// Read-only view of the files Arma sees: `<PBO prefix>\<entry path>` across a set of PBOs.
/// Lookups are case-insensitive and accept `\` or `/` with or without a leading separator.
/// When several PBOs provide the same path, the first archive passed to `init` wins.
/// Thread-safe.
final class VirtualFileSystem {
    let archives: [PBOArchive]
    private var byPrefix: [String: [Int]] = [:]
    private var maxPrefixDepth = 0
    private var cache: [String: String] = [:]
    private let lock = NSLock()

    init(archives: [PBOArchive]) {
        self.archives = archives
        for (i, a) in archives.enumerated() {
            let p = VirtualFileSystem.root(of: a)
            let depth = p.split(separator: "\\").count
            // Real prefixes are a few levels (z\ace\addons\common); every lookup tries each depth up to the
            // deepest one registered, so an absurd prefix from a hostile PBO would make all lookups slow.
            guard depth <= VirtualFileSystem.maxPrefixParts else { continue }
            byPrefix[p, default: []].append(i)
            maxPrefixDepth = max(maxPrefixDepth, depth)
        }
    }

    static let maxPrefixParts = 16

    /// A PBO's root in the file system: its `prefix` header, or its file name when it has none
    /// (Arma mounts prefix-less PBOs under their own name).
    static func root(of a: PBOArchive) -> String {
        a.prefix.isEmpty ? a.url.deletingPathExtension().lastPathComponent.lowercased() : a.prefix
    }

    /// Virtual path of an entry, e.g. `x\cba\addons\main\script_macros_common.hpp`.
    static func path(of e: PBOEntry, in a: PBOArchive) -> String { root(of: a) + "\\" + e.path }

    /// Lowercase, `\`-separated, no leading/trailing or doubled separators, `.` and `..` resolved.
    static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for p in path.lowercased().split(whereSeparator: { $0 == "\\" || $0 == "/" }) {
            if p == "." { continue }
            if p == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(p)
        }
        return parts.joined(separator: "\\")
    }

    func locate(_ path: String) -> (archive: PBOArchive, entry: PBOEntry)? {
        let parts = VirtualFileSystem.normalize(path).split(separator: "\\")
        guard parts.count > 1 else { return nil }
        lock.lock(); defer { lock.unlock() }   // PBOArchive builds its path index lazily
        for k in stride(from: min(maxPrefixDepth, parts.count - 1), through: 1, by: -1) {
            guard let list = byPrefix[parts[0..<k].joined(separator: "\\")] else { continue }
            let rest = parts[k...].joined(separator: "\\")
            for i in list { if let e = archives[i].entry(rest) { return (archives[i], e) } }
        }
        return nil
    }

    func exists(_ path: String) -> Bool { locate(path) != nil }

    /// File contents as text (UTF-8, falling back to Latin-1; BOM stripped). Cached.
    func read(_ path: String) -> String? {
        let key = VirtualFileSystem.normalize(path)
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        guard let (a, e) = locate(key), let data = a.contents(of: e) else { return nil }
        let text = VirtualFileSystem.decode(data)
        lock.lock(); cache[key] = text; lock.unlock()
        return text
    }

    static func decode(_ data: Data) -> String {
        var data = data
        while data.starts(with: [0xEF, 0xBB, 0xBF]) { data = data.dropFirst(3) }   // a loop: a file can repeat the mark thousands of times
        if data.starts(with: [0xFF, 0xFE]), let s = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) { return s }
        if data.starts(with: [0xFE, 0xFF]), let s = String(data: data.dropFirst(2), encoding: .utf16BigEndian) { return s }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Preprocessor

struct PreprocessResult {
    var text: String
    /// `kind: detail` lines, e.g. `unresolved include: \x\foo.hpp (x\bar\config.cpp:3)`.
    var diagnostics: [String]
    /// Normalized paths tested by `#if __has_include(...)`: the output depends on whether they exist.
    var usedHasInclude: [String]
}

/// Bohemia's config preprocessor, following the BI wiki "PreProcessor Commands" and the way CBA
/// macros are built. Arma rules that differ from C and are mirrored here:
/// - nothing inside double quotes is expanded; single quotes are ordinary text (so `'GVAR(x)'` expands);
/// - macro arguments are fully expanded before `#`/`##` (so `QUOTE(GVAR(x))` and `DOUBLES(PREFIX,COMPONENT)` work);
/// - arguments split on commas outside parentheses and double-quoted strings, but `[...]` does not protect commas,
///   and a comma inside a string or plain nested parentheses is dropped (engine quirk) — but a nested call of a
///   function-like macro keeps its own arguments intact, which is what CBA's `QUOTE([ARR_2(a,b)] call f)` relies on;
/// - `#` before a non-name is dropped, `##` simply joins what surrounds it, argument whitespace is kept;
/// - `#include` paths starting with `\` are absolute, others are relative to the including file (`..` allowed);
/// - `__has_include` paths must start with `\`, otherwise the test is false;
/// - `\` at the very end of a line joins it with the next one anywhere in the file.
struct ConfigPreprocessor {
    let vfs: VirtualFileSystem
    /// Answers `__has_include` for a normalized path; nil means "exists in `vfs`".
    let hasInclude: ((String) -> Bool)?
    /// Object-like macros defined before every file. Game-version values model current Arma 3.
    var predefined: [String: String] = [
        "__ARMA__": "1", "__ARMA3__": "1",
        "__GAME_VER__": "02.20.152984", "__GAME_VER_MAJ__": "02", "__GAME_VER_MIN__": "20", "__GAME_BUILD__": "152984",
    ]
    var maxIncludeDepth = 32
    var maxIncludes = 20_000   // per run: a file that includes itself twice per level would otherwise mean 2^32
    var maxExpansionDepth = 128
    var maxExpansions = 2_000_000
    var maxOutputBytes = 64 << 20
    /// Per run. Real configs take milliseconds; this cuts off inputs that are slow rather than deep
    /// (unterminated nested calls, self-including files with huge lines, enormous parameter lists).
    var maxSeconds: TimeInterval = 3

    init(vfs: VirtualFileSystem, hasInclude: ((String) -> Bool)? = nil) {
        self.vfs = vfs
        self.hasInclude = hasInclude
    }

    /// Preprocess `text`, which lives at virtual path `path` (used for relative includes and `__FILE__`).
    func process(_ text: String, path: String) -> PreprocessResult {
        let run = PreprocessorRun(self)
        run.processFile(Array(text.utf8), path: VirtualFileSystem.normalize(path), depth: 0)
        return PreprocessResult(text: String(decoding: run.out, as: UTF8.self),
                                diagnostics: run.diagnostics, usedHasInclude: run.hasIncludes)
    }
}

private let NL: UInt8 = 0x0A, CR: UInt8 = 0x0D, SP: UInt8 = 0x20, TAB: UInt8 = 0x09
private let QUOTE: UInt8 = 0x22, HASH: UInt8 = 0x23, LP: UInt8 = 0x28, RP: UInt8 = 0x29
private let COMMA: UInt8 = 0x2C, SLASH: UInt8 = 0x2F, STAR: UInt8 = 0x2A, BSLASH: UInt8 = 0x5C
private let LT: UInt8 = 0x3C, GT: UInt8 = 0x3E

@inline(__always) private func isIdentStart(_ c: UInt8) -> Bool {
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F
}
@inline(__always) private func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
@inline(__always) private func isIdent(_ c: UInt8) -> Bool { isIdentStart(c) || isDigit(c) }
@inline(__always) private func isBlank(_ c: UInt8) -> Bool { c == SP || c == TAB }

/// End of the double-quoted string starting at `i`: just past the closing quote, or at the newline/end
/// when unterminated (a stray quote never swallows more than its line).
private func stringEnd(_ s: [UInt8], _ i: Int) -> Int {
    var j = i + 1
    while j < s.count && s[j] != QUOTE && s[j] != NL { j += 1 }
    return j < s.count && s[j] == QUOTE ? j + 1 : j
}

private func word(_ s: [UInt8], _ i: Int) -> Int {
    var j = i
    while j < s.count && isIdent(s[j]) { j += 1 }
    return j
}

private func text(_ s: ArraySlice<UInt8>) -> String { String(decoding: s, as: UTF8.self) }

/// State for one `process` call: the macro table is shared by the file and everything it includes.
private final class PreprocessorRun {
    struct Macro {
        let params: [String]?   // nil = object-like
        let variadic: Bool
        let body: [UInt8]
        let simple: Bool        // object-like without `#`: body is used as-is
    }
    struct Cond { let parentActive: Bool; var taking: Bool; var taken: Bool; var sawElse: Bool }

    let cfg: ConfigPreprocessor
    var macros: [String: Macro] = [:]
    var out: [UInt8] = []
    var diagnostics: [String] = []
    var hasIncludes: [String] = []
    var file = ""
    var line = 1
    var counter = 0
    var expansions = 0
    var includes = 0
    var aborted = false
    lazy var now = Date()
    let deadline: Date
    var steps = 0
    var hasIncludeSet = Set<String>()

    init(_ cfg: ConfigPreprocessor) {
        self.cfg = cfg
        deadline = Date().addingTimeInterval(cfg.maxSeconds)
        for (k, v) in cfg.predefined { define(k, params: nil, body: Array(v.utf8)) }
    }

    /// True once the run has stopped. Counts work in the hot loops and checks the clock every 1024 steps,
    /// or every time with `now` for steps that are expensive on their own.
    func outOfBudget(now: Bool = false) -> Bool {
        if aborted { return true }
        steps &+= 1
        guard now || steps & 0x3FF == 0, Date() > deadline else { return false }
        diag("time limit", "stopped after \(Int(cfg.maxSeconds)) s")
        aborted = true
        return true
    }

    func diag(_ kind: String, _ detail: String) {
        guard diagnostics.count < 200 else { return }
        diagnostics.append("\(kind): \(detail) (\(file):\(line))")
    }

    func define(_ name: String, params: [String]?, body: [UInt8]) {
        let variadic = params?.last == "..."
        macros[name] = Macro(params: params, variadic: variadic, body: body,
                             simple: params == nil && !body.contains(HASH))
    }

    // MARK: Files and directives

    func processFile(_ raw: [UInt8], path: String, depth: Int) {
        let (savedFile, savedLine) = (file, line)
        file = path
        line = 1
        defer { file = savedFile; line = savedLine }

        let src = stripComments(raw)
        var conds: [Cond] = []
        var active: Bool { conds.last.map { $0.parentActive && $0.taking } ?? true }
        var pending: [UInt8] = []
        var pendingLine = 1
        var physical = 1   // line number of the next physical line

        func flush() {
            guard !pending.isEmpty else { return }
            line = pendingLine
            out.append(contentsOf: expand(pending, [], 0))
            pending.removeAll(keepingCapacity: true)
            if out.count > cfg.maxOutputBytes, !aborted { diag("output limit", "stopped after \(cfg.maxOutputBytes) bytes"); aborted = true }
        }

        var i = 0
        while i < src.count, !outOfBudget() {
            // One logical line: physical lines joined where a line ends with `\`.
            var logical: [UInt8] = []
            var lines = 0
            while i < src.count {
                var j = i
                while j < src.count && src[j] != NL { j += 1 }
                lines += 1
                if j > i && src[j - 1] == BSLASH && j < src.count {
                    logical.append(contentsOf: src[i..<(j - 1)])
                    i = j + 1
                    continue
                }
                logical.append(contentsOf: src[i..<j])
                i = j < src.count ? j + 1 : j
                break
            }
            let startLine = physical
            physical += lines
            let newlines = [UInt8](repeating: NL, count: lines)

            var k = 0
            while k < logical.count && isBlank(logical[k]) { k += 1 }
            guard k < logical.count && logical[k] == HASH else {
                if active {
                    if pending.isEmpty { pendingLine = startLine }
                    pending.append(contentsOf: logical)
                    pending.append(contentsOf: newlines)
                } else {
                    out.append(contentsOf: newlines)
                }
                continue
            }

            flush()
            line = startLine
            k += 1
            while k < logical.count && isBlank(logical[k]) { k += 1 }
            let nameEnd = word(logical, k)
            let directive = text(logical[k..<nameEnd])
            var rest = Array(logical[nameEnd...])

            switch directive {
            case "ifdef", "ifndef":
                let name = firstWord(rest)
                let on = active && ((macros[name] != nil) == (directive == "ifdef"))
                conds.append(Cond(parentActive: active, taking: on, taken: on, sawElse: false))
            case "if":
                let on = active && evaluate(rest)
                conds.append(Cond(parentActive: active, taking: on, taken: on, sawElse: false))
            case "elif":
                guard var c = conds.popLast() else { diag("unbalanced #if", "#elif without #if"); break }
                let on = c.parentActive && !c.taken && evaluate(rest)
                c.taking = on
                c.taken = c.taken || on
                conds.append(c)
            case "else":
                guard var c = conds.popLast() else { diag("unbalanced #if", "#else without #if"); break }
                if c.sawElse { diag("unbalanced #if", "second #else") }
                c.taking = !c.taken
                c.taken = true
                c.sawElse = true
                conds.append(c)
            case "endif":
                if conds.popLast() == nil { diag("unbalanced #if", "#endif without #if") }
                // The engine emits whatever follows `#endif` on its line.
                if active, let start = rest.firstIndex(where: { !isBlank($0) }) { out.append(contentsOf: expand(Array(rest[start...]), [], 1)) }
            case _ where !active:
                break
            case "define":
                defineDirective(&rest)
            case "undef":
                macros[firstWord(rest)] = nil
            case "include":
                include(rest, depth: depth)
            case "pragma", "":
                break   // `#pragma hemtt …` and similar are ignored by the game
            default:
                diag("unknown directive", "#" + directive)
            }
            out.append(contentsOf: newlines)
        }
        flush()
        if !conds.isEmpty {
            line = physical
            diag("unbalanced #if", "\(conds.count) unterminated conditional block(s)")
        }
    }

    /// Removes `//` and `/* */` comments outside double-quoted strings (block comments keep their
    /// newlines so line numbers stay right) and normalizes CRLF/CR to LF.
    func stripComments(_ s: [UInt8]) -> [UInt8] {
        var o = [UInt8]()
        o.reserveCapacity(s.count)
        var i = 0
        let n = s.count
        while i < n {
            let c = s[i]
            if c == CR {
                o.append(NL)
                i += (i + 1 < n && s[i + 1] == NL) ? 2 : 1
            } else if c == QUOTE {
                var j = i + 1
                while j < n && s[j] != QUOTE && s[j] != NL && s[j] != CR { j += 1 }
                if j < n && s[j] == QUOTE { j += 1 }
                o.append(contentsOf: s[i..<j])
                i = j
            } else if c == SLASH && i + 1 < n && s[i + 1] == SLASH {
                while i < n && s[i] != NL && s[i] != CR { i += 1 }
            } else if c == SLASH && i + 1 < n && s[i + 1] == STAR {
                i += 2
                var newlines = 0
                while i < n && !(s[i] == STAR && i + 1 < n && s[i + 1] == SLASH) {
                    if s[i] == NL { newlines += 1 }
                    i += 1
                }
                i = min(n, i + 2)
                o.append(SP)
                o.append(contentsOf: [UInt8](repeating: NL, count: newlines))
            } else {
                o.append(c)
                i += 1
            }
        }
        return o
    }

    func firstWord(_ s: [UInt8]) -> String {
        var i = 0
        while i < s.count && isBlank(s[i]) { i += 1 }
        return text(s[i..<word(s, i)])
    }

    func defineDirective(_ s: inout [UInt8]) {
        var i = 0
        while i < s.count && isBlank(s[i]) { i += 1 }
        let nameEnd = word(s, i)
        guard nameEnd > i, isIdentStart(s[i]) else { diag("malformed #define", text(s[...])); return }
        let name = text(s[i..<nameEnd])
        i = nameEnd
        var params: [String]?
        if i < s.count && s[i] == LP {   // `(` right after the name: function-like
            guard let close = s[i...].firstIndex(of: RP) else { diag("malformed #define", name); return }
            params = text(s[(i + 1)..<close]).split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if params == [""] { params = [] }
            i = close + 1
        }
        while i < s.count && s[i] == SP { i += 1 }   // spaces (not tabs) before the body are swallowed
        var end = s.count
        while end > i && (isBlank(s[end - 1]) || s[end - 1] == NL) { end -= 1 }
        define(name, params: params, body: Array(s[i..<end]))
    }

    /// The quoted (`"…"` or `<…>`) path at the start of `s`.
    func quotedPath(_ s: [UInt8]) -> String? {
        var i = 0
        while i < s.count && isBlank(s[i]) { i += 1 }
        guard i < s.count, s[i] == QUOTE || s[i] == LT else { return nil }
        let close = s[i] == QUOTE ? QUOTE : GT
        guard let end = s[(i + 1)...].firstIndex(of: close) else { return nil }
        return text(s[(i + 1)..<end])
    }

    func include(_ rest: [UInt8], depth: Int) {
        guard let raw = quotedPath(rest) else { diag("malformed #include", text(rest[...]).trimmingCharacters(in: .whitespaces)); return }
        guard depth < cfg.maxIncludeDepth else { diag("include depth limit", raw); return }
        guard !outOfBudget(now: true) else { return }
        includes += 1
        guard includes <= cfg.maxIncludes, out.count <= cfg.maxOutputBytes else {
            if !aborted { diag("include limit", "stopped at \(raw)") }
            aborted = true
            return
        }
        let dir = file.split(separator: "\\").dropLast().joined(separator: "\\")
        func resolve(_ r: String) -> String {
            VirtualFileSystem.normalize(r.hasPrefix("\\") || r.hasPrefix("/") ? r : dir + "\\" + r)
        }
        // The second candidate repairs obfuscated names that were decoded as Latin-1 (see `utf8Reading`).
        guard let (path, content) = [raw, PreprocessorRun.utf8Reading(raw)].compactMap({ $0 }).map(resolve)
                .lazy.compactMap({ p in self.cfg.vfs.read(p).map { (p, $0) } }).first else { diag("unresolved include", raw); return }
        processFile(Array(content.utf8), path: path, depth: depth + 1)
    }

    // MARK: #if expressions

    func evaluate(_ s: [UInt8]) -> Bool {
        // `defined(X)` and `__has_include("…")` are resolved before macro expansion.
        var pre: [UInt8] = []
        var i = 0
        while i < s.count {
            let c = s[i]
            if c == QUOTE { let j = stringEnd(s, i); pre.append(contentsOf: s[i..<j]); i = j; continue }
            guard isIdentStart(c) else { pre.append(c); i += 1; continue }
            let j = word(s, i)
            let w = text(s[i..<j])
            i = j
            if w == "defined" {
                var k = i
                while k < s.count && isBlank(s[k]) { k += 1 }
                let paren = k < s.count && s[k] == LP
                if paren { k += 1; while k < s.count && isBlank(s[k]) { k += 1 } }
                let e = word(s, k)
                let name = text(s[k..<e])
                k = e
                if paren { while k < s.count && isBlank(s[k]) { k += 1 }; if k < s.count && s[k] == RP { k += 1 } }
                pre.append(macros[name] != nil ? 0x31 : 0x30)
                i = k
            } else if w == "__has_include" {
                var k = i
                while k < s.count && isBlank(s[k]) { k += 1 }
                guard k < s.count, s[k] == LP, let close = s[(k + 1)...].firstIndex(of: RP),
                      let raw = quotedPath(Array(s[(k + 1)..<close])) else {
                    diag("#if expression", "malformed __has_include"); return false
                }
                pre.append(hasFile(raw) ? 0x31 : 0x30)
                i = close + 1
            } else {
                pre.append(contentsOf: Array(w.utf8))
            }
        }
        let expr = expand(pre, [], 1)
        var p = ExpressionParser(s: expr)
        guard let v = p.parse() else {
            diag("#if expression", "cannot evaluate '\(text(expr[...]).trimmingCharacters(in: .whitespaces))'")
            return false
        }
        return v != 0
    }

    func hasFile(_ raw: String) -> Bool {
        guard raw.hasPrefix("\\") else { return false }   // the engine requires an absolute path
        let path = VirtualFileSystem.normalize(raw)
        if hasIncludeSet.insert(path).inserted { hasIncludes.append(path) }
        let alt = PreprocessorRun.utf8Reading(raw).map(VirtualFileSystem.normalize)
        if let ask = cfg.hasInclude { return ask(path) || alt.map(ask) == true }
        return cfg.vfs.exists(path) || alt.map(cfg.vfs.exists) == true
    }

    /// A path from a Latin-1-decoded file re-read as UTF-8 (invalid bytes replaced, as `PBOArchive` does for
    /// entry names), or nil when that changes nothing. Obfuscated PBOs include such byte-garbled names. Must be
    /// applied before lowercasing, which would corrupt the Latin-1 bytes.
    static func utf8Reading(_ path: String) -> String? {
        guard path.unicodeScalars.contains(where: { $0.value > 0x7F }),
              path.unicodeScalars.allSatisfy({ $0.value <= 0xFF }) else { return nil }
        let s = String(decoding: path.unicodeScalars.map { UInt8($0.value) }, as: UTF8.self)
        return s == path ? nil : s
    }

    // MARK: Macro expansion

    /// Expands macros in `s`. `disabled` holds the macros being expanded (no self-recursion);
    /// `depth` 0 is file text, where newlines advance `line`.
    func expand(_ s: [UInt8], _ disabled: Set<String>, _ depth: Int) -> [UInt8] {
        var o = [UInt8]()
        o.reserveCapacity(s.count)
        var i = 0
        let n = s.count
        while i < n {
            if outOfBudget() { o.append(contentsOf: s[i..<n]); break }   // stopped: keep the rest as written
            let c = s[i]
            if c == QUOTE { let j = stringEnd(s, i); o.append(contentsOf: s[i..<j]); i = j; continue }
            if c == NL { if depth == 0 { line += 1 }; o.append(c); i += 1; continue }
            if isDigit(c) { let j = word(s, i); o.append(contentsOf: s[i..<j]); i = j; continue }
            guard isIdentStart(c) else { o.append(c); i += 1; continue }
            let j = word(s, i)
            let name = text(s[i..<j])
            guard let m = macros[name] else {
                if let b = builtin(name) { o.append(contentsOf: b) } else { o.append(contentsOf: s[i..<j]) }
                i = j
                continue
            }
            if disabled.contains(name) || aborted { o.append(contentsOf: s[i..<j]); i = j; continue }
            if m.params == nil {
                o.append(contentsOf: m.simple ? rescan(m.body, name, disabled, depth) : rescan(substitute(m, []), name, disabled, depth))
                checkOutput(o, name)
                i = j
                continue
            }
            var k = j
            while k < n && isBlank(s[k]) { k += 1 }
            guard k < n && s[k] == LP else { o.append(contentsOf: s[i..<j]); i = j; continue }   // name without call
            guard let (args, end) = arguments(s, k) else {
                diag("unterminated macro call", name)
                o.append(contentsOf: s[i..<j])
                i = j
                continue
            }
            // Arguments are expanded before `rescan` checks depth, so nested calls F(F(F(…))) need their own cap.
            guard depth < cfg.maxExpansionDepth else {
                diag("expansion depth limit", name)
                o.append(contentsOf: s[i..<end])
                i = end
                continue
            }
            let expanded = args.map { expand($0, disabled, depth + 1) }
            // Stopped while expanding the arguments: substituting now would only multiply what's there.
            guard !aborted else { o.append(contentsOf: s[i..<end]); i = end; continue }
            o.append(contentsOf: rescan(substitute(m, bind(m, name, expanded)), name, disabled, depth))
            checkOutput(o, name)
            if depth == 0 { for b in s[k..<end] where b == NL { line += 1 } }
            i = end
        }
        return o
    }

    /// The output cap counts the block being expanded, not only what earlier blocks wrote.
    func checkOutput(_ building: [UInt8], _ name: String) {
        guard out.count + building.count > cfg.maxOutputBytes, !aborted else { return }
        diag("output limit", "stopped expanding at \(name)")
        aborted = true
    }

    func rescan(_ body: [UInt8], _ name: String, _ disabled: Set<String>, _ depth: Int) -> [UInt8] {
        expansions += 1
        if expansions > cfg.maxExpansions || out.count + body.count > cfg.maxOutputBytes {
            if !aborted { diag("expansion limit", "stopped expanding at \(name)") }
            aborted = true
            return body
        }
        guard depth < cfg.maxExpansionDepth else { diag("expansion depth limit", name); return body }
        var d = disabled
        d.insert(name)
        return expand(body, d, depth + 1)
    }

    /// Arguments of the call whose `(` is at `open`, and the index just past its `)`.
    func arguments(_ s: [UInt8], _ open: Int) -> ([[UInt8]], Int)? {
        var args: [[UInt8]] = []
        var cur: [UInt8] = []
        var depth = 1
        var i = open + 1
        while i < s.count {
            if outOfBudget() { return nil }
            let c = s[i]
            if c == QUOTE {   // strings protect commas, which the engine then drops from them
                cur.append(c)
                i += 1
                while i < s.count && s[i] != QUOTE && s[i] != NL {
                    if s[i] != COMMA { cur.append(s[i]) }
                    i += 1
                }
                if i < s.count && s[i] == QUOTE { cur.append(QUOTE); i += 1 }
                continue
            }
            if isIdentStart(c) {
                let j = word(s, i)
                var k = j
                while k < s.count && isBlank(s[k]) { k += 1 }
                if k < s.count && s[k] == LP, macros[text(s[i..<j])]?.params != nil, let end = callEnd(s, k) {
                    cur.append(contentsOf: s[i..<end])
                    i = end
                } else {
                    cur.append(contentsOf: s[i..<j])
                    i = j
                }
                continue
            }
            if c == LP { depth += 1 }
            else if c == RP {
                depth -= 1
                if depth == 0 { args.append(cur); return (args, i + 1) }
            } else if c == COMMA {   // splits at the top level; dropped inside nested parentheses
                if depth == 1 { args.append(cur); cur = [] }
                i += 1
                continue
            }
            cur.append(c)
            i += 1
        }
        return nil
    }

    /// Index just past the `)` matching the `(` at `open` (double-quoted strings skipped), or nil.
    func callEnd(_ s: [UInt8], _ open: Int) -> Int? {
        var depth = 0, i = open
        while i < s.count {
            if outOfBudget() { return nil }
            switch s[i] {
            case QUOTE: i = stringEnd(s, i); continue
            case LP: depth += 1
            case RP: depth -= 1; if depth == 0 { return i + 1 }
            default: break
            }
            i += 1
        }
        return nil
    }

    /// Matches call arguments to parameters; extra arguments fold into the last one, missing ones are empty.
    func bind(_ m: Macro, _ name: String, _ args: [[UInt8]]) -> [[UInt8]] {
        let params = m.params ?? []
        var a = args
        if a.count == 1 && a[0].allSatisfy({ isBlank($0) || $0 == NL }) && (params.isEmpty || (m.variadic && params.count == 1)) {
            a = []
        }
        if m.variadic {
            let fixed = params.count - 1
            if a.count < fixed { diag("macro argument count", "\(name) expects at least \(fixed), got \(a.count)") }
            while a.count < fixed { a.append([]) }
            let rest = a[fixed...].reduce(into: [UInt8]()) { r, x in if !r.isEmpty { r.append(COMMA) }; r.append(contentsOf: x) }
            return Array(a[..<fixed]) + [rest]
        }
        if a.count != params.count {
            diag("macro argument count", "\(name) expects \(params.count), got \(a.count)")
            if a.count > params.count, let last = params.indices.last {
                a = Array(a[..<last]) + [a[last...].reduce(into: [UInt8]()) { r, x in if !r.isEmpty { r.append(COMMA) }; r.append(contentsOf: x) }]
            }
            while a.count < params.count { a.append([]) }
        }
        return a
    }

    /// Body with parameters replaced, `#param` stringized and `##` removed (joining its neighbours).
    func substitute(_ m: Macro, _ args: [[UInt8]]) -> [UInt8] {
        let params = m.params ?? []
        func value(_ w: String) -> [UInt8]? {
            if let p = params.firstIndex(of: w), p < args.count, !(m.variadic && p == params.count - 1) { return args[p] }
            if m.variadic && w == "__VA_ARGS__" { return args.last ?? [] }
            return nil
        }
        let b = m.body
        var o = [UInt8]()
        o.reserveCapacity(b.count)
        var i = 0
        while i < b.count {
            let c = b[i]
            if c == QUOTE { let j = stringEnd(b, i); o.append(contentsOf: b[i..<j]); i = j; continue }
            if c == HASH {
                if i + 1 < b.count && b[i + 1] == HASH { o.append(HASH); o.append(HASH); i += 2; continue }
                guard i + 1 < b.count, isIdentStart(b[i + 1]) else { i += 1; continue }   // `#` before a non-name is dropped
                let j = word(b, i + 1)
                o.append(QUOTE)
                o.append(contentsOf: value(text(b[(i + 1)..<j])) ?? Array(b[(i + 1)..<j]))
                o.append(QUOTE)
                i = j
                continue
            }
            if isDigit(c) { let j = word(b, i); o.append(contentsOf: b[i..<j]); i = j; continue }
            if isIdentStart(c) {
                let j = word(b, i)
                if let v = value(text(b[i..<j])) { o.append(contentsOf: v) } else { o.append(contentsOf: b[i..<j]) }
                i = j
                continue
            }
            o.append(c)
            i += 1
        }
        guard o.contains(HASH) else { return o }
        var pasted = [UInt8]()
        pasted.reserveCapacity(o.count)
        i = 0
        while i < o.count {
            if o[i] == QUOTE { let j = stringEnd(o, i); pasted.append(contentsOf: o[i..<j]); i = j; continue }
            if o[i] == HASH && i + 1 < o.count && o[i + 1] == HASH { i += 2; continue }
            pasted.append(o[i])
            i += 1
        }
        return pasted
    }

    func builtin(_ name: String) -> [UInt8]? {
        guard name.hasPrefix("__") else { return nil }
        func quoted(_ s: String) -> [UInt8] { Array(("\"" + s + "\"").utf8) }
        let utc = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: now)
        let local = Calendar.current.dateComponents(in: .current, from: now)
        func two(_ v: Int?) -> String { String(format: "%02d", v ?? 0) }
        let fileName = String(file.split(separator: "\\").last ?? "")
        switch name {
        case "__LINE__": return Array(String(line).utf8)
        case "__FILE__": return quoted(file)
        case "__FILE_NAME__": return quoted(fileName)
        case "__FILE_SHORT__": return quoted((fileName as NSString).deletingPathExtension)
        case "__COUNTER__": defer { counter += 1 }; return Array(String(counter).utf8)
        case "__COUNTER_RESET__": counter = 0; return []
        case "__DATE_ARR__":
            return Array([local.year, local.month, local.day, local.hour, local.minute, local.second]
                .map { String($0 ?? 0) }.joined(separator: ",").utf8)
        case "__DATE_STR__":
            return quoted("\(local.year ?? 0)/\(two(local.month))/\(two(local.day)), \(two(local.hour)):\(two(local.minute)):\(two(local.second))")
        case "__DATE_STR_ISO8601__":
            return quoted("\(utc.year ?? 0)-\(two(utc.month))-\(two(utc.day))T\(two(utc.hour)):\(two(utc.minute)):\(two(utc.second))Z")
        case "__TIME__": return Array("\(two(local.hour)):\(two(local.minute)):\(two(local.second))".utf8)
        case "__TIME_UTC__": return Array("\(two(utc.hour)):\(two(utc.minute)):\(two(utc.second))".utf8)
        case "__DAY__": return Array(String(utc.day ?? 0).utf8)
        case "__MONTH__": return Array(String(utc.month ?? 0).utf8)
        case "__YEAR__": return Array(String(utc.year ?? 0).utf8)
        case "__TIMESTAMP_UTC__": return Array(String(Int(now.timeIntervalSince1970)).utf8)
        case "__RAND_INT8__", "__RAND_INT16__", "__RAND_INT32__", "__RAND_INT64__",
             "__RAND_UINT8__", "__RAND_UINT16__", "__RAND_UINT32__", "__RAND_UINT64__":
            return [0x30]   // deterministic stand-in for the engine's random value
        default: return nil
        }
    }
}

/// Integer/decimal expression for `#if`: `|| && == != < > <= >= + - * / % !`, parentheses.
/// Unknown names are 0. Returns nil on a syntax error.
private struct ExpressionParser {
    let s: [UInt8]
    var i = 0
    /// Unary operators and parentheses recurse; real `#if` lines nest a few levels, so 64 is plenty.
    var depth = 0

    init(s: [UInt8]) { self.s = s }

    mutating func parse() -> Double? {
        guard let v = or(), (skip(), i == s.count).1 else { return nil }
        return v
    }

    mutating func skip() { while i < s.count && s[i] <= SP { i += 1 } }

    mutating func eat(_ op: String) -> Bool {
        skip()
        let b = Array(op.utf8)
        guard i + b.count <= s.count, Array(s[i..<(i + b.count)]) == b else { return false }
        // `<` must not match the start of `<=`, `!` not `!=`.
        if b.count == 1, i + 1 < s.count, s[i + 1] == 0x3D, op != "=" { return false }
        i += b.count
        return true
    }

    mutating func or() -> Double? {
        guard var v = and() else { return nil }
        while eat("||") { guard let r = and() else { return nil }; v = (v != 0 || r != 0) ? 1 : 0 }
        return v
    }

    mutating func and() -> Double? {
        guard var v = cmp() else { return nil }
        while eat("&&") { guard let r = cmp() else { return nil }; v = (v != 0 && r != 0) ? 1 : 0 }
        return v
    }

    mutating func cmp() -> Double? {
        guard var v = sum() else { return nil }
        while true {
            let ops: [(String, (Double, Double) -> Bool)] = [("==", (==)), ("!=", (!=)), ("<=", (<=)), (">=", (>=)), ("<", (<)), (">", (>))]
            guard let (_, f) = ops.first(where: { eat($0.0) }) else { return v }
            guard let r = sum() else { return nil }
            v = f(v, r) ? 1 : 0
        }
    }

    mutating func sum() -> Double? {
        guard var v = product() else { return nil }
        while true {
            if eat("+") { guard let r = product() else { return nil }; v += r }
            else if eat("-") { guard let r = product() else { return nil }; v -= r }
            else { return v }
        }
    }

    mutating func product() -> Double? {
        guard var v = unary() else { return nil }
        while true {
            if eat("*") { guard let r = unary() else { return nil }; v *= r }
            else if eat("/") { guard let r = unary(), r != 0 else { return nil }; v /= r }
            else if eat("%") { guard let r = unary(), r != 0 else { return nil }; v = v.truncatingRemainder(dividingBy: r) }
            else { return v }
        }
    }

    mutating func unary() -> Double? {
        depth += 1
        defer { depth -= 1 }
        guard depth <= 64 else { return nil }
        if eat("!") { return unary().map { $0 == 0 ? 1 : 0 } }
        if eat("-") { return unary().map { -$0 } }
        if eat("+") { return unary() }
        if eat("(") { guard let v = or(), eat(")") else { return nil }; return v }
        skip()
        guard i < s.count else { return nil }
        let start = i
        if isIdentStart(s[i]) { i = word(s, i); return 0 }
        if s[i] == 0x30, i + 1 < s.count, s[i + 1] | 0x20 == 0x78 {
            i = word(s, i)
            return UInt64(text(s[(start + 2)..<i]), radix: 16).map(Double.init)
        }
        while i < s.count && (isDigit(s[i]) || s[i] == 0x2E) { i += 1 }
        return Double(text(s[start..<i]))
    }
}
