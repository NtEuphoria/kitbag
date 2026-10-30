// PBO archive reading shared by every health check: header, entry table, LZSS.
import Foundation

enum ParseError: Error { case eof, format(String) }

/// Little-endian cursor over a Data buffer (works on memory-mapped files and slices).
struct ByteReader {
    let d: Data
    var i: Int

    init(_ d: Data, at i: Int = 0) { self.d = d; self.i = i }

    var atEnd: Bool { i >= d.count }

    mutating func u8() throws -> UInt8 {
        guard i < d.count else { throw ParseError.eof }
        defer { i += 1 }
        return d[d.startIndex + i]
    }

    mutating func u32() throws -> UInt32 {
        var v: UInt32 = 0
        for k in 0..<4 { v |= UInt32(try u8()) << (8 * k) }
        return v
    }

    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }

    mutating func f32() throws -> Float { Float(bitPattern: try u32()) }

    mutating func skip(_ n: Int) throws {
        guard i + n <= d.count else { throw ParseError.eof }
        i += n
    }

    /// NUL-terminated string. Invalid UTF-8 bytes are replaced rather than failing.
    mutating func cstr() throws -> String {
        let start = i
        while try u8() != 0 {}
        return String(decoding: d[(d.startIndex + start)..<(d.startIndex + i - 1)], as: UTF8.self)
    }

    /// Variable-length int used by rapified configs (7 bits per byte, little-endian).
    mutating func cint() throws -> Int {
        var v = 0, shift = 0
        while true {
            let b = try u8()
            v |= Int(b & 0x7F) << shift
            shift += 7
            if b & 0x80 == 0 { return v }
            if shift > 35 { throw ParseError.format("compressed int too long") }
        }
    }
}

struct PBOEntry {
    /// Lowercased, backslash-separated, relative to the archive prefix (e.g. `functions\fn_init.sqf`).
    let path: String
    let packing: UInt32
    let originalSize: Int
    /// Absolute offset of the stored bytes within the archive.
    let offset: Int
    let size: Int

    var isCompressed: Bool { packing == PBOArchive.cprsMagic && size != originalSize }
}

/// A memory-mapped PBO. Reading entries is cheap; only touched pages are loaded from disk.
final class PBOArchive {
    static let versMagic: UInt32 = 0x5665_7273   // "Vers" header-extension entry
    static let cprsMagic: UInt32 = 0x4370_7273   // "Cprs" LZSS-compressed entry

    let url: URL
    /// Lowercased, backslash-separated, no leading/trailing backslash. "" when the PBO has none.
    let prefix: String
    /// Header extension key/value pairs (prefix, product, version, …), keys lowercased.
    let properties: [String: String]
    let entries: [PBOEntry]
    private let data: Data
    private lazy var byPath: [String: Int] = {
        var m = [String: Int](minimumCapacity: entries.count)
        for (i, e) in entries.enumerated() where m[e.path] == nil { m[e.path] = i }
        return m
    }()

    init(url: URL) throws {
        self.url = url
        let d = try Data(contentsOf: url, options: .alwaysMapped)
        self.data = d
        var r = ByteReader(d)
        var props: [String: String] = [:]
        var raw: [(String, UInt32, Int, Int)] = []
        while true {
            let name = try r.cstr()
            let packing = try r.u32(), original = try r.u32()
            _ = try r.u32(); _ = try r.u32()   // reserved, timestamp
            let size = try r.u32()
            if name.isEmpty && packing == PBOArchive.versMagic {
                while true {
                    let key = try r.cstr()
                    if key.isEmpty { break }
                    props[key.lowercased()] = try r.cstr()
                }
                continue
            }
            if name.isEmpty { break }
            raw.append((name, packing, Int(original), Int(size)))
        }
        var offset = r.i
        var list: [PBOEntry] = []
        list.reserveCapacity(raw.count)
        for (name, packing, original, size) in raw {
            list.append(PBOEntry(path: PBOArchive.normalize(name), packing: packing,
                                 originalSize: original, offset: offset, size: size))
            offset += size
        }
        self.entries = list
        self.properties = props
        self.prefix = PBOArchive.normalize(props["prefix"] ?? "")
    }

    /// Lowercase, `/` → `\`, trim leading/trailing separators.
    static func normalize(_ path: String) -> String {
        var p = path.lowercased().replacingOccurrences(of: "/", with: "\\")
        while p.hasPrefix("\\") { p.removeFirst() }
        while p.hasSuffix("\\") { p.removeLast() }
        return p
    }

    /// Entry by path relative to the prefix (any case, either separator).
    func entry(_ path: String) -> PBOEntry? {
        byPath[PBOArchive.normalize(path)].map { entries[$0] }
    }

    /// `prefix\path` — the path other mods use in `#include "\…"` and script references.
    func virtualPath(_ e: PBOEntry) -> String { prefix.isEmpty ? e.path : prefix + "\\" + e.path }

    /// Entry bytes, decompressed when stored with LZSS. Returns nil when the entry is truncated.
    func contents(of e: PBOEntry) -> Data? {
        guard e.offset >= 0, e.offset + e.size <= data.count else { return nil }
        let slice = Data(data[(data.startIndex + e.offset)..<(data.startIndex + e.offset + e.size)])
        return e.packing == PBOArchive.cprsMagic ? PBOArchive.lzss(slice, length: e.originalSize) : slice
    }

    /// Bohemia's LZSS variant: a flag byte governs 8 items; set bit = literal byte,
    /// clear bit = 2-byte back-reference (12-bit distance, 4-bit length + 3).
    static func lzss(_ src: Data, length: Int) -> Data {
        let s = [UInt8](src)
        var out = [UInt8]()
        out.reserveCapacity(length)
        var i = 0
        while out.count < length && i < s.count {
            let flags = s[i]; i += 1
            for bit in 0..<8 where out.count < length {
                if flags & (1 << bit) != 0 {
                    guard i < s.count else { return Data(out) }
                    out.append(s[i]); i += 1
                } else {
                    guard i + 1 < s.count else { return Data(out) }
                    let start = out.count - (Int(s[i]) | (Int(s[i + 1] & 0xF0) << 4))
                    let count = Int(s[i + 1] & 0x0F) + 3
                    i += 2
                    for k in 0..<count {
                        let p = start + k
                        out.append(p >= 0 && p < out.count ? out[p] : 0x20)
                    }
                }
            }
        }
        return Data(out)
    }
}

/// The PBOs Arma actually loads from a mod or game folder: `addons/*.pbo` only
/// (case-insensitive), never `optionals/`, `keys/` or nested folders.
func loadedPBOs(in folder: URL) -> [URL] {
    let fm = FileManager.default
    guard let top = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil),
          let addons = top.first(where: { $0.lastPathComponent.lowercased() == "addons" }),
          let files = try? fm.contentsOfDirectory(at: addons, includingPropertiesForKeys: nil) else { return [] }
    return files.filter { $0.pathExtension.lowercased() == "pbo" }.sorted { $0.path < $1.path }
}
