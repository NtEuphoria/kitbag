// Independent second reader (shared ByteReader, no tree) that records format facts the parser
// relies on: header constants, body layout vs the enum table, type codes, duplicate names.
import Foundation

struct Census {
    var entryTypes: [Int: Int] = [:], valueTypes: [Int: Int] = [:], elemTypes: [Int: Int] = [:]
    var appendFlags: [UInt32: Int] = [:]
    var classes = 0, externals = 0, deletes = 0, maxDepth = 0, maxArrayDepth = 0
    var dupClass: [String] = [], dupProp: [String] = [], externalThenDefined: [String] = [], propAndClass: [String] = []
    var floats = 0, floatMismatches = 0, floatsNotDescription: [String] = []
    var headerOdd: String?
    var enumOffset = 0, enumCount = 0, enumOK = false
    var bodiesPastEnum = false, bodiesContiguous = false, bodiesOverlap = false
    /// Binarize layout: every body is followed by a u32 holding the end of its subtree (trailers
    /// included), the root's equals the enum offset, and bodies + trailers tile [16, enumOffset).
    var binarizeTrailers = false
    private var spans: [(Int, Int)] = []
    private var trailersOK = true

    static func of(_ d: Data) throws -> Census {
        var c = Census()
        var h = ByteReader(d, at: 4)
        let zero = try h.u32(), eight = try h.u32()
        c.enumOffset = Int(try h.u32())
        if zero != 0 || eight != 8 { c.headerOdd = "\(zero)/\(eight)" }
        let rootEnd = try c.body(d, at: 16, depth: 0, path: "")
        c.spans.sort { $0.0 < $1.0 }
        c.binarizeTrailers = c.trailersOK && rootEnd == c.enumOffset && c.spans.first?.0 == 16
            && zip(c.spans, c.spans.dropFirst()).allSatisfy { $1.0 == $0.1 + 4 }
        c.bodiesOverlap = zip(c.spans, c.spans.dropFirst()).contains { $1.0 < $0.1 }
        c.bodiesContiguous = c.spans.first?.0 == 16 && zip(c.spans, c.spans.dropFirst()).allSatisfy { $1.0 == $0.1 }
            && c.spans.last?.1 == c.enumOffset
        c.bodiesPastEnum = c.spans.contains { $0.1 > c.enumOffset }
        if c.enumOffset >= 16, c.enumOffset <= d.count - 4 {
            var r = ByteReader(d, at: c.enumOffset)
            if let n = try? r.u32() {
                c.enumCount = Int(n)
                var ok = true
                for _ in 0..<min(Int(n), 100_000) {
                    guard (try? r.cstr()) != nil, (try? r.u32()) != nil else { ok = false; break }
                }
                c.enumOK = ok && r.i == d.count
            }
        }
        return c
    }

    /// Returns where this class's subtree ends if Binarize trailers are present.
    @discardableResult
    private mutating func body(_ d: Data, at off: Int, depth: Int, path: String) throws -> Int {
        guard depth < 200 else { throw ParseError.format("census depth") }
        maxDepth = max(maxDepth, depth)
        var r = ByteReader(d, at: off)
        _ = try r.cstr()
        let n = try r.cint()
        var classNames: [String: Bool] = [:]   // lowercased → external
        var props = Set<String>()
        var kids: [(Int, String)] = []
        func noteClass(_ name: String, external: Bool) {
            let k = name.lowercased()
            if let was = classNames[k] {
                if was && !external { externalThenDefined.append(path + "/" + name) } else { dupClass.append(path + "/" + name + (external ? " (ext)" : "")) }
            }
            if props.contains(k) { propAndClass.append(path + "/" + name) }
            classNames[k] = external && (classNames[k] ?? true)
        }
        func noteProp(_ name: String) {
            let k = name.lowercased()
            if !props.insert(k).inserted { dupProp.append(path + "/" + name) }
            if classNames[k] != nil { propAndClass.append(path + "/" + name) }
        }
        for _ in 0..<n {
            let t = Int(try r.u8())
            entryTypes[t, default: 0] += 1
            switch t {
            case 0:
                let name = try r.cstr()
                kids.append((Int(try r.u32()), name)); classes += 1; noteClass(name, external: false)
            case 1:
                let sub = Int(try r.u8()); valueTypes[sub, default: 0] += 1
                noteProp(try r.cstr()); try scalar(&r, sub)
            case 2:
                noteProp(try r.cstr()); try array(&r, depth: 1)
            case 3:
                noteClass(try r.cstr(), external: true); externals += 1
            case 4:
                _ = try r.cstr(); deletes += 1
            case 5:
                appendFlags[try r.u32(), default: 0] += 1
                _ = try r.cstr(); try array(&r, depth: 1)
            default:
                throw ParseError.format("census: entry type \(t)")
            }
        }
        spans.append((off, r.i))
        var t = ByteReader(d, at: r.i)
        let trailer = try? t.u32()
        var end = r.i + 4
        for (o, name) in kids { end = max(end, try body(d, at: o, depth: depth + 1, path: path + "/" + name)) }
        if trailer.map(Int.init) != end { trailersOK = false }
        return end
    }

    private mutating func array(_ r: inout ByteReader, depth: Int) throws {
        maxArrayDepth = max(maxArrayDepth, depth)
        let n = try r.cint()
        for _ in 0..<n {
            let t = Int(try r.u8()); elemTypes[t, default: 0] += 1
            if t == 3 { try array(&r, depth: depth + 1) } else { try scalar(&r, t) }
        }
    }

    private mutating func scalar(_ r: inout ByteReader, _ t: Int) throws {
        switch t {
        case 0, 4: _ = try r.cstr()
        case 1:
            let f = try r.f32()
            floats += 1
            if f.isFinite, RapParser.widen(f) != Double(f.description) {
                floatMismatches += 1
                if floatsNotDescription.count < 20 { floatsNotDescription.append("\(f)") }
            }
        case 2: _ = try r.u32()
        case 6: _ = try r.u32(); _ = try r.u32()
        default: throw ParseError.format("census: value type \(t)")
        }
    }
}

/// `run inspect <pbo> [entry]`: header, enum table and body layout of one rapified entry.
enum Inspect {
    static func run(_ pbo: String, _ entry: String) {
        guard let a = try? PBOArchive(url: URL(fileURLWithPath: pbo)), let e = a.entry(entry), let d = a.contents(of: e) else { return print("cannot read") }
        var h = ByteReader(d, at: 4)
        let z = (try? h.u32()) ?? 0, eight = (try? h.u32()) ?? 0, eo = Int((try? h.u32()) ?? 0)
        print("size \(d.count) header \(z)/\(eight) enumOffset \(eo) packing \(String(e.packing, radix: 16)) stored \(e.size) original \(e.originalSize)")
        if eo + 4 <= d.count {
            var r = ByteReader(d, at: eo)
            let n = (try? r.u32()) ?? 0
            print("enum count \(n)")
            for k in 0..<min(Int(n), 400) {
                guard let name = try? r.cstr(), let v = try? r.u32() else { print("enum \(k) unreadable at \(r.i)"); break }
                if k < 5 || k > Int(n) - 3 { print("  enum \(k): \(name) = \(v)") }
            }
            print("enum table ends at \(r.i), file ends at \(d.count); tail: \(Array(d.suffix(max(0, d.count - r.i)).prefix(64)))")
        }
        // Body spans in file order, gaps between them.
        var spans: [(Int, Int, String)] = []
        func walk(_ off: Int, _ path: String) {
            var r = ByteReader(d, at: off)
            guard (try? r.cstr()) != nil, let n = try? r.cint() else { return }
            var kids: [(Int, String)] = []
            for _ in 0..<n {
                guard let t = try? r.u8() else { return }
                switch t {
                case 0: if let name = try? r.cstr(), let o = try? r.u32() { kids.append((Int(o), name)) }
                case 1: let s = (try? r.u8()) ?? 0; _ = try? r.cstr(); if s == 0 || s == 4 { _ = try? r.cstr() } else if s == 6 { try? r.skip(8) } else { try? r.skip(4) }
                case 2: _ = try? r.cstr(); skipArray(&r)
                case 3, 4: _ = try? r.cstr()
                case 5: try? r.skip(4); _ = try? r.cstr(); skipArray(&r)
                default: return
                }
            }
            spans.append((off, r.i, path))
            for (o, name) in kids { walk(o, path + "/" + name) }
        }
        func skipArray(_ r: inout ByteReader) {
            guard let n = try? r.cint() else { return }
            for _ in 0..<n {
                guard let t = try? r.u8() else { return }
                switch t { case 0, 4: _ = try? r.cstr(); case 3: skipArray(&r); case 6: try? r.skip(8); default: try? r.skip(4) }
            }
        }
        walk(16, "")
        spans.sort { $0.0 < $1.0 }
        var gaps = 0
        for (a, b) in zip(spans, spans.dropFirst()) where b.0 != a.1 {
            gaps += 1
            if b.0 < a.1 { print("overlap: \(b.2) at \(b.0) starts inside \(a.2) (\(a.0)..<\(a.1))"); continue }
            if gaps <= 5 { print("gap \(a.1)..<\(b.0) after \(a.2) before \(b.2): \(Array(d[(d.startIndex + a.1)..<(d.startIndex + min(b.0, a.1 + 24))]))") }
        }
        print("bodies \(spans.count), gaps \(gaps), first \(spans.first.map { "\($0.0)" } ?? "-"), last ends \(spans.last.map { "\($0.1)" } ?? "-")")
    }
}
