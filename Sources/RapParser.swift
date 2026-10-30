// Rapified (binarized) config reader: config.bin, and any other file starting with `\0raP`.
import Foundation

/// Reads Bohemia's rapified config format into a `ConfigClass` tree.
///
/// Layout: `\0raP`, u32 0, u32 8, u32 offset of the enum table, then the root class body at 16.
/// A body is the parent class name (asciiz, empty when none), a compressed entry count, then entries:
/// 0 class (name, u32 body offset) · 1 value (subtype, name, value) · 2 array (name, array) ·
/// 3 `class X;` (name) · 4 `delete X;` (name) · 5 `name[] += {…}` (u32 flags = 1, name, array).
/// Scalars: 0 string, 1 float32, 2 int32, 4 variable (asciiz), 6 int64; array elements may also be
/// 3 (nested array). An array is a compressed count followed by type-tagged elements.
/// Binarize follows each body with a u32 (end of that class's subtree) and armake doesn't, so bodies
/// are only reached through their offsets; the header's 0/8 and the enum table are never read.
///
/// Malformed input throws `ParseError`, never traps: every read is bounds-checked, body offsets must
/// point past the header, bodies may not overlap (so a cycle can't loop and a crafted file can't
/// make parsing quadratic), and class and array nesting are capped.
enum RapParser {
    static let maxClassDepth = 64
    static let maxArrayDepth = 32

    static func isRapified(_ data: Data) -> Bool {
        data.count >= 16 && data.prefix(4).elementsEqual([0x00, 0x72, 0x61, 0x50])
    }

    static func parse(_ data: Data) throws -> ConfigClass {
        guard isRapified(data) else { throw ParseError.format("not a rapified config") }
        return try data.withUnsafeBytes { raw in
            var p = RapReader(b: raw)
            let root = ConfigClass(name: "")
            try p.body(root, at: 16, depth: 0)
            try p.checkDisjoint()
            return root
        }
    }

    /// Binarize stores most numbers as float32. Widen via the shortest decimal that rounds back to the
    /// same float, so `0.1` reads as 0.1 (what a text config.cpp gives), not 0.100000001490116.
    static func widen(_ f: Float) -> Double {
        let d = Double(f)
        if !d.isFinite || (d.rounded() == d && abs(d) < 16_777_216) { return d }   // exact small integers
        return Double(f.description) ?? d
    }
}

/// Bounds-checked cursor over the raw bytes; holds the overlap and depth guards.
private struct RapReader {
    let b: UnsafeRawBufferPointer
    var i = 0
    var consumed = 0            // bytes read across all class bodies; more than the file means overlap
    var bodies = Set<Int>()
    var spans: [(start: Int, end: Int)] = []

    init(b: UnsafeRawBufferPointer) { self.b = b }

    /// Bodies written by any real tool never share bytes; overlap means corrupt offsets.
    mutating func checkDisjoint() throws {
        spans.sort { $0.start < $1.start }
        for k in spans.indices.dropFirst() where spans[k].start < spans[k - 1].end {
            throw fail("class bodies overlap at \(spans[k].start)")
        }
    }

    mutating func body(_ c: ConfigClass, at offset: Int, depth: Int) throws {
        guard depth <= RapParser.maxClassDepth else { throw fail("classes nested deeper than \(RapParser.maxClassDepth)") }
        guard offset >= 16, offset < b.count else { throw fail("class \(c.name) body offset \(offset) outside the file") }
        guard bodies.insert(offset).inserted else { throw fail("class \(c.name) reuses the body at \(offset)") }
        i = offset
        let parent = try cstr()
        if !parent.isEmpty { c.parent = parent }
        let count = try cint()
        var nested: [(ConfigClass, Int)] = []
        for _ in 0..<count {
            switch try u8() {
            case 0:
                let child = ConfigClass(name: try cstr())
                nested.append((child, Int(try u32())))
                c.children.append(child)
            case 1:
                let type = try u8()
                let name = try cstr()
                c.properties[name.lowercased()] = try scalar(type)
            case 2:
                let name = try cstr()
                c.properties[name.lowercased()] = .array(try array(depth: 1))
            case 3:
                c.children.append(ConfigClass(name: try cstr(), isExternal: true))
            case 4:
                c.deletes.append(try cstr())
            case 5:
                let flags = try u32()
                let name = try cstr()
                let items = try array(depth: 1)
                // Every tool writes 1 (`+=`). Another value has no known meaning; the entry's length
                // doesn't depend on it, so skip it rather than lose the whole file.
                if flags == 1 { c.appends[name.lowercased(), default: []] += items }
            case let t:
                throw fail("unknown entry type \(t) at \(i - 1)")
            }
        }
        consumed += i - offset
        guard consumed <= b.count else { throw fail("class bodies overlap (at \(c.name))") }
        spans.append((offset, i))
        for (child, at) in nested { try body(child, at: at, depth: depth + 1) }
    }

    mutating func array(depth: Int) throws -> [ConfigValue] {
        guard depth <= RapParser.maxArrayDepth else { throw fail("arrays nested deeper than \(RapParser.maxArrayDepth)") }
        let n = try cint()
        var out: [ConfigValue] = []
        out.reserveCapacity(min(n, (b.count - i) / 2))   // every element takes at least 2 bytes
        for _ in 0..<n {
            let type = try u8()
            out.append(type == 3 ? .array(try array(depth: depth + 1)) : try scalar(type))
        }
        return out
    }

    mutating func scalar(_ type: UInt8) throws -> ConfigValue {
        switch type {
        case 0, 4: return .string(try cstr())
        case 1: return .number(RapParser.widen(Float(bitPattern: try u32())))
        case 2: return .number(Double(Int32(bitPattern: try u32())))
        case 6:
            let lo = UInt64(try u32()), hi = UInt64(try u32())
            return .number(Double(Int64(bitPattern: hi << 32 | lo)))
        default: throw fail("unknown value type \(type) at \(i - 1)")
        }
    }

    mutating func u8() throws -> UInt8 {
        guard i < b.count else { throw ParseError.eof }
        defer { i += 1 }
        return b[i]
    }

    mutating func u32() throws -> UInt32 {
        guard b.count - i >= 4 else { throw ParseError.eof }
        defer { i += 4 }
        return UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }

    /// 7 bits per byte, little-endian, high bit = more; at most 5 bytes.
    mutating func cint() throws -> Int {
        var v = 0
        for shift in stride(from: 0, through: 28, by: 7) {
            let byte = try u8()
            v |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return v }
        }
        throw fail("compressed int too long at \(i)")
    }

    /// NUL-terminated string; invalid UTF-8 is replaced rather than rejected.
    mutating func cstr() throws -> String {
        guard i < b.count, let base = b.baseAddress,
              let nul = memchr(base + i, 0, b.count - i) else { throw ParseError.eof }
        let end = base.distance(to: UnsafeRawPointer(nul))
        defer { i = end + 1 }
        return String(decoding: UnsafeRawBufferPointer(rebasing: b[i..<end]), as: UTF8.self)
    }

    func fail(_ message: String) -> ParseError { .format(message) }
}
