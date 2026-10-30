// Mutation fuzzing: damaged copies of real configs must never crash or hang the preprocessor or the parser.
// `run fuzz [mutationsPerFile]` — a crash (trap) ends the process, so reaching the summary means none happened.
import Foundation

enum Fuzz {
    struct RNG { var s: UInt64; mutating func next(_ n: Int) -> Int { s = s &* 6364136223846793005 &+ 1442695040888963407; return Int((s >> 33) % UInt64(max(n, 1))) } }

    static let snippets = ["{", "}", "(", ")", "[", "]", "\"", "'", "\\", "#", "##", ",", ";", "\n", "/*", "*/", "//", "=", "+=", ":",
                           "#define X(a,b) a##b\n", "#define Y Y Y\n", "#include \"\\x\\cba\\addons\\main\\script_macros_common.hpp\"\n",
                           "#if __has_include(", "#ifdef ", "#else\n", "#endif\n", "#undef ", "QUOTE(", "GVAR(", "class A: B {", "__EVAL(", "__EXEC(", "\u{FFFD}", "\0"]

    static func mutate(_ src: [UInt8], _ rng: inout RNG) -> [UInt8] {
        var b = src
        for _ in 0...rng.next(4) {
            guard !b.isEmpty else { break }
            let at = rng.next(b.count)
            switch rng.next(5) {
            case 0: b = Array(b[..<at])
            case 1: b.removeSubrange(at..<min(b.count, at + 1 + rng.next(300)))
            case 2: let end = min(b.count, at + 1 + rng.next(300)); b.insert(contentsOf: b[at..<end], at: rng.next(b.count))
            case 3: b.insert(contentsOf: Array(snippets[rng.next(snippets.count)].utf8), at: at)
            default: b[at] = UInt8(rng.next(256))
            }
        }
        return b
    }

    /// `run replay <file> <virtual path> [parser]`: process one saved input with timings (for hangs and slow cases).
    static func replay(file: String, path: String, parserOnly: Bool) {
        let (mods, vanilla, _) = Corpus.load()
        let vfs = VirtualFileSystem(archives: mods.flatMap(\.archives) + vanilla)
        let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        let t0 = Date()
        var pre = text
        if !parserOnly {
            let r = ConfigPreprocessor(vfs: vfs).process(text, path: path)
            pre = r.text
            print("preprocess \(String(format: "%.3f", Date().timeIntervalSince(t0)))s, \(text.utf8.count) -> \(pre.utf8.count) bytes, diagnostics \(r.diagnostics.prefix(3))")
        }
        let t1 = Date()
        do { _ = try TextConfigParser.parse(pre); print("parse ok") } catch { print("parse error: \(error)") }
        print("parse \(String(format: "%.3f", Date().timeIntervalSince(t1)))s")
    }

    static func run(perFile: Int) {
        let (mods, vanilla, _) = Corpus.load()
        let vfs = VirtualFileSystem(archives: mods.flatMap(\.archives) + vanilla)
        var files: [(String, [UInt8])] = []
        for m in mods { for a in m.archives { for e in a.entries where Corpus.fileName(e.path) == "config.cpp" && e.originalSize < 120_000 {
            if let d = a.contents(of: e) { files.append((VirtualFileSystem.path(of: e, in: a), Array(VirtualFileSystem.decode(d).utf8))) }
        } } }
        files.sort { $0.0 < $1.0 }
        // A spread of files, plus every macro-heavy one (ALiVE / CBA-style).
        var picked = files.enumerated().filter { $0.offset % 6 == 0 || $0.element.0.hasPrefix("x\\") }.map(\.element)
        if picked.count > 90 { picked = Array(picked.prefix(90)) }
        let pp = ConfigPreprocessor(vfs: vfs)
        var rng = RNG(s: 0x9E3779B97F4A7C15)
        var runs = 0, parseErrors = 0, diagnostics = 0
        var slowest = (0.0, "")
        let t0 = Date()
        for (path, src) in picked {
            for _ in 0..<perFile {
                let text = String(decoding: mutate(src, &rng), as: UTF8.self)
                // FUZZ_TRACE=<dir>: keep the input being processed, so a hang can be reproduced from the last file.
                if let dir = ProcessInfo.processInfo.environment["FUZZ_TRACE"] {
                    try? Data(text.utf8).write(to: URL(fileURLWithPath: dir).appendingPathComponent("current.txt"))
                    try? path.write(to: URL(fileURLWithPath: dir).appendingPathComponent("current.path"), atomically: true, encoding: .utf8)
                }
                let s = Date()
                let r = pp.process(text, path: path)
                diagnostics += r.diagnostics.count
                do { _ = try TextConfigParser.parse(r.text) } catch { parseErrors += 1 }
                let dt = Date().timeIntervalSince(s)
                if dt > slowest.0 { slowest = (dt, path) }
                if dt > 1.0 {
                    print("slow: \(String(format: "%.2f", dt))s run \(runs) \(path) (\(text.utf8.count) bytes)"); fflush(stdout)
                    if let dir = ProcessInfo.processInfo.environment["FUZZ_TRACE"] {
                        try? Data(text.utf8).write(to: URL(fileURLWithPath: dir).appendingPathComponent("slow-\(runs).txt"))
                        try? path.write(to: URL(fileURLWithPath: dir).appendingPathComponent("slow-\(runs).path"), atomically: true, encoding: .utf8)
                    }
                }
                runs += 1
            }
        }
        // The parser alone, on damaged preprocessed text (the preprocessor above rarely lets such text through).
        var parserRuns = 0, parserErrors = 0, parserSlowest = 0.0
        for (path, src) in picked {
            let clean = Array(pp.process(String(decoding: src, as: UTF8.self), path: path).text.utf8)
            for _ in 0..<perFile {
                let text = String(decoding: mutate(clean, &rng), as: UTF8.self)
                if let dir = ProcessInfo.processInfo.environment["FUZZ_TRACE"] {
                    try? Data(text.utf8).write(to: URL(fileURLWithPath: dir).appendingPathComponent("current.txt"))
                }
                let s = Date()
                do { _ = try TextConfigParser.parse(text) } catch { parserErrors += 1 }
                let dt = Date().timeIntervalSince(s)
                if dt > 0.5, dt > parserSlowest, let dir = ProcessInfo.processInfo.environment["FUZZ_TRACE"] {
                    try? Data(text.utf8).write(to: URL(fileURLWithPath: dir).appendingPathComponent("pslow.txt"))
                }
                parserSlowest = max(parserSlowest, dt)
                parserRuns += 1
            }
        }
        print("fuzz (parser only): \(parserRuns) mutated preprocessed configs, no crash; \(parserErrors) parse errors, slowest \(String(format: "%.2f", parserSlowest))s")
        print("fuzz: \(runs) mutated configs from \(picked.count) files, no crash; \(parseErrors) parse errors, \(diagnostics) diagnostics, slowest \(String(format: "%.2f", slowest.0))s (\(slowest.1)), total \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
    }
}
