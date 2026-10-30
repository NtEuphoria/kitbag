// Minimal rapified-config writer for building test inputs (bodies laid out like Binarize: root at 16,
// each class's body written after its parent's, enum table last).
import Foundation

indirect enum TEntry {
    case cls(String, parent: String = "", [TEntry])
    case ext(String)
    case del(String)
    case str(String, String)
    case variable(String, String)
    case f32(String, Float)
    case i32(String, Int32)
    case i64(String, Int64)
    case arr(String, [TElem])
    case append(String, flags: UInt32 = 1, [TElem])
}

indirect enum TElem { case s(String), f(Float), i(Int32), l(Int64), v(String), a([TElem]) }

struct RapWriter {
    var buf: [UInt8] = []

    static func build(_ root: [TEntry], rootParent: String = "", enums: [(String, UInt32)] = []) -> Data {
        var w = RapWriter()
        w.buf = [0x00, 0x72, 0x61, 0x50]
        w.u32(0); w.u32(8); w.u32(0)
        w.body(rootParent, root)
        let enumOffset = w.buf.count
        w.patch(12, UInt32(enumOffset))
        w.u32(UInt32(enums.count))
        for (n, v) in enums { w.cstr(n); w.u32(v) }
        return Data(w.buf)
    }

    mutating func body(_ parent: String, _ entries: [TEntry]) {
        cstr(parent); cint(entries.count)
        var pending: [(Int, String, [TEntry])] = []
        for e in entries {
            switch e {
            case let .cls(n, p, children): u8(0); cstr(n); pending.append((buf.count, p, children)); u32(0)
            case let .ext(n): u8(3); cstr(n)
            case let .del(n): u8(4); cstr(n)
            case let .str(n, v): u8(1); u8(0); cstr(n); cstr(v)
            case let .variable(n, v): u8(1); u8(4); cstr(n); cstr(v)
            case let .f32(n, v): u8(1); u8(1); cstr(n); u32(v.bitPattern)
            case let .i32(n, v): u8(1); u8(2); cstr(n); u32(UInt32(bitPattern: v))
            case let .i64(n, v): u8(1); u8(6); cstr(n); u64(UInt64(bitPattern: v))
            case let .arr(n, items): u8(2); cstr(n); array(items)
            case let .append(n, flags, items): u8(5); u32(flags); cstr(n); array(items)
            }
        }
        for (at, p, children) in pending {
            patch(at, UInt32(buf.count))
            body(p, children)
        }
    }

    mutating func array(_ items: [TElem]) {
        cint(items.count)
        for e in items {
            switch e {
            case let .s(v): u8(0); cstr(v)
            case let .f(v): u8(1); u32(v.bitPattern)
            case let .i(v): u8(2); u32(UInt32(bitPattern: v))
            case let .l(v): u8(6); u64(UInt64(bitPattern: v))
            case let .v(v): u8(4); cstr(v)
            case let .a(v): u8(3); array(v)
            }
        }
    }

    mutating func u8(_ v: UInt8) { buf.append(v) }
    mutating func u32(_ v: UInt32) { for k in 0..<4 { buf.append(UInt8(truncatingIfNeeded: v >> (8 * k))) } }
    mutating func u64(_ v: UInt64) { for k in 0..<8 { buf.append(UInt8(truncatingIfNeeded: v >> (8 * k))) } }
    mutating func cstr(_ s: String) { buf.append(contentsOf: Array(s.utf8)); buf.append(0) }
    mutating func cint(_ v: Int) {
        var v = v
        repeat {
            var b = UInt8(v & 0x7F); v >>= 7
            if v > 0 { b |= 0x80 }
            buf.append(b)
        } while v > 0
    }
    mutating func patch(_ at: Int, _ v: UInt32) { for k in 0..<4 { buf[at + k] = UInt8(truncatingIfNeeded: v >> (8 * k)) } }
}
