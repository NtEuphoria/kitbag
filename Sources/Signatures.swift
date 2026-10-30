// Multiplayer signature checks: reads a mod's .bikey/.bisign files and verifies each loaded
// PBO's signatures the way a server with `verifySignatures = 2` does (RSA over SHA-1 hashes).
// Only matters when joining servers that verify signatures; single-player ignores all of it.
import Foundation

// MARK: - Key and signature files

/// A Bohemia public key: the whole `.bikey` file, also embedded in every `.bisign`.
/// Layout: authority (C string), u32 blob length, then a Microsoft PUBLICKEYBLOB:
/// `06 02 00 00 | 00 24 00 00 | "RSA1" | u32 bits | u32 exponent | modulus (bits/8 bytes, little-endian)`.
struct BIPublicKey: Hashable {
    let authority: String
    let bits: Int
    let exponent: UInt32
    let modulus: [UInt8]

    /// Short stable fingerprint of the key material (first 8 hex digits of SHA-1 of the modulus),
    /// so two keys with the same authority name but different contents can be told apart.
    var keyID: String {
        var h = SHA1()
        h.update(modulus)
        return h.finalize().prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    init?(data: Data) {
        var r = ByteReader(data)
        guard let k = try? BIPublicKey.read(&r) else { return nil }
        self = k
    }

    private init(authority: String, bits: Int, exponent: UInt32, modulus: [UInt8]) {
        self.authority = authority; self.bits = bits; self.exponent = exponent; self.modulus = modulus
    }

    static func read(_ r: inout ByteReader) throws -> BIPublicKey {
        let name = try r.cstr()
        let blobLength = Int(try r.u32())
        let start = r.i
        guard try r.u8() == 0x06, try r.u8() == 0x02 else { throw ParseError.format("not a PUBLICKEYBLOB") }
        try r.skip(2)
        _ = try r.u32()                                   // ALG_ID (CALG_RSA_SIGN)
        guard try r.u32() == 0x3141_5352 else { throw ParseError.format("missing RSA1 magic") }
        let bits = Int(try r.u32())
        guard bits >= 512, bits <= 8192, bits % 32 == 0 else { throw ParseError.format("odd key size \(bits)") }
        let exponent = try r.u32()
        let modulus = try r.bytes(bits / 8)
        guard r.i - start == blobLength else { throw ParseError.format("key blob length mismatch") }
        return BIPublicKey(authority: name, bits: bits, exponent: exponent, modulus: modulus)
    }
}

/// A `.bisign`: the signer's public key, then three RSA signatures (little-endian) over SHA-1
/// hashes of the PBO, with the format version (2 or 3) stored between the first and second.
struct BISignature {
    let key: BIPublicKey
    let version: UInt32
    let sig1: [UInt8], sig2: [UInt8], sig3: [UInt8]
    var authority: String { key.authority }

    /// The three SHA-1 hashes the signer signed (each decoded with the embedded key), or nil
    /// when a block doesn't decode to PKCS#1 v1.5 padding. Used for diagnostics.
    var signedHashes: [[UInt8]]? {
        let blocks = [sig1, sig2, sig3].compactMap { RSA.decrypt($0, key) }
        guard blocks.count == 3, blocks.allSatisfy({ RSA.matches($0, RSA.digest(of: $0)) }) else { return nil }
        return blocks.map(RSA.digest(of:))
    }

    init?(data: Data) {
        var r = ByteReader(data)
        do {
            key = try BIPublicKey.read(&r)
            let n = key.bits / 8
            guard Int(try r.u32()) == n else { return nil }
            sig1 = try r.bytes(n)
            version = try r.u32()
            guard Int(try r.u32()) == n else { return nil }
            sig2 = try r.bytes(n)
            guard Int(try r.u32()) == n else { return nil }
            sig3 = try r.bytes(n)
            guard r.atEnd else { return nil }
        } catch { return nil }
    }
}

fileprivate extension ByteReader {
    mutating func bytes(_ n: Int) throws -> [UInt8] {
        guard n >= 0, i + n <= d.count else { throw ParseError.eof }
        defer { i += n }
        return [UInt8](d[(d.startIndex + i)..<(d.startIndex + i + n)])
    }

    /// NUL-terminated byte string, kept raw (file names are hashed byte for byte).
    mutating func cbytes() throws -> [UInt8] {
        let start = i
        while try u8() != 0 {}
        return [UInt8](d[(d.startIndex + start)..<(d.startIndex + i - 1)])
    }
}

// MARK: - Report

/// Something a server that verifies signatures would act on. Messages never name the mod;
/// the caller prefixes it.
struct SignatureFinding: Codable, Hashable {
    enum Kind: String, Codable {
        /// Loaded PBOs without any `.bisign`: verifying servers kick ("unsigned data").
        case unsigned
        /// The signature doesn't match the PBO's contents (changed after signing): verifying servers kick.
        case invalidSignature
        /// A `.bisign` file that can't be parsed.
        case unreadableSignature
        /// The mod ships a key with the signer's name but different key material, so that key can't verify it.
        case keyMismatch
        /// No key for the signer is shipped with the mod; server admins must get it elsewhere.
        case keyNotShipped
        /// Loaded PBOs signed by different keys (sometimes legitimate, often repacked content).
        case multipleAuthorities
    }
    enum Severity: Int, Codable, Comparable {
        case info, warning
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    let kind: Kind
    let severity: Severity
    let message: String
    /// PBO file names (or key/signature file names) the finding is about.
    let files: [String]
}

/// Signature state of one mod folder. Codable so callers can cache it by folder modification date.
struct SignatureReport: Codable {
    /// `invalid` only when the PBO's bytes differ from what was signed (its checksum isn't the signed
    /// one), so a server will reject it. `unverified`: the PBO is byte-identical to what was signed but
    /// Kitbag couldn't reproduce a secondary hash — a gap in Kitbag, not the mod; treated as signed.
    enum Verdict: String, Codable { case valid, invalid, unverified, unreadable }

    struct Key: Codable, Hashable {
        let file: String          // path relative to the mod folder
        let authority: String
        let keyID: String
    }

    struct Signature: Codable {
        let file: String          // .bisign file name
        let authority: String
        let keyID: String
        let version: Int          // bisign format version (2 or 3); both are accepted by servers
        let verdict: Verdict
        /// Which hash failed, for invalid signatures (e.g. "scripts changed").
        let detail: String?
    }

    struct PBO: Codable {
        let name: String
        var signatures: [Signature]
        var isSigned: Bool { !signatures.isEmpty }
    }

    var keys: [Key] = []
    var pbos: [PBO] = []
    var findings: [SignatureFinding] = []
}

// MARK: - Checks

enum Signatures {
    /// Reads keys and signatures of the PBOs Arma loads (`addons/*.pbo`) and verifies each signature
    /// cryptographically. `verify: false` skips the RSA/SHA-1 work (header parsing only).
    static func check(modFolder: URL, verify: Bool = true) -> SignatureReport {
        var report = SignatureReport()
        let fm = FileManager.default

        var shipped: [(key: BIPublicKey, file: String)] = []
        for url in keyFiles(in: modFolder) {
            let rel = String(url.path.dropFirst(modFolder.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let d = try? Data(contentsOf: url), let k = BIPublicKey(data: d) else { continue }
            shipped.append((k, rel))
            report.keys.append(.init(file: rel, authority: k.authority, keyID: k.keyID))
        }

        let pbos = loadedPBOs(in: modFolder)
        let siblings = (pbos.first.map { (try? fm.contentsOfDirectory(at: $0.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? [] }) ?? []
        let bisigns = siblings.filter { $0.pathExtension.lowercased() == "bisign" }
        var unreadable: [String] = []

        for pbo in pbos {
            let stem = pbo.lastPathComponent.lowercased() + "."
            var entry = SignatureReport.PBO(name: pbo.lastPathComponent, signatures: [])
            let mine = bisigns.filter { $0.lastPathComponent.lowercased().hasPrefix(stem) }.sorted { $0.path < $1.path }
            guard !mine.isEmpty else { report.pbos.append(entry); continue }
            let raw = verify ? RawPBO(url: pbo) : nil
            for s in mine {
                guard let d = try? Data(contentsOf: s), let sig = BISignature(data: d) else {
                    unreadable.append(s.lastPathComponent)
                    entry.signatures.append(.init(file: s.lastPathComponent, authority: "", keyID: "", version: 0,
                                                  verdict: .unreadable, detail: "not a valid .bisign file"))
                    continue
                }
                var verdict = SignatureReport.Verdict.valid
                var detail: String?
                if verify {
                    if let raw {
                        (verdict, detail) = raw.verify(sig)
                    } else {
                        verdict = .unreadable
                        detail = "the PBO itself can't be read"
                    }
                }
                entry.signatures.append(.init(file: s.lastPathComponent, authority: sig.authority, keyID: sig.key.keyID,
                                              version: Int(sig.version), verdict: verdict, detail: detail))
            }
            report.pbos.append(entry)
        }

        report.findings = findings(report, shipped: shipped.map(\.key), unreadableSignatures: unreadable)
        return report
    }

    /// Every `.bikey` in the mod (keys/, key/, root, addons/, any case); keys inside `optionals/`
    /// belong to optional PBOs and are ignored.
    static func keyFiles(in modFolder: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: modFolder, includingPropertiesForKeys: nil) else { return [] }
        var out: [URL] = []
        while let u = e.nextObject() as? URL {
            if u.lastPathComponent.lowercased() == "optionals" { e.skipDescendants(); continue }
            if u.pathExtension.lowercased() == "bikey" { out.append(u) }
        }
        return out.sorted { $0.path < $1.path }
    }

    private static func findings(_ r: SignatureReport, shipped: [BIPublicKey], unreadableSignatures: [String]) -> [SignatureFinding] {
        var out: [SignatureFinding] = []
        let total = r.pbos.count
        guard total > 0 else { return [] }
        func sample(_ names: [String]) -> String {
            names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " +\(names.count - 3) more" : "")
        }

        // A damaged .bisign is reported on its own below; "unsigned" means there is no signature file at all.
        let unsigned = r.pbos.filter { $0.signatures.isEmpty }.map(\.name)
        if unsigned.count == total {
            out.append(.init(kind: .unsigned, severity: .info,
                             message: "None of its \(total) addon file\(total == 1 ? " is" : "s are") signed. Servers that verify signatures will kick you while it's loaded.",
                             files: unsigned))
        } else if !unsigned.isEmpty {
            out.append(.init(kind: .unsigned, severity: .warning,
                             message: "\(unsigned.count) of its \(total) addon files have no signature (\(sample(unsigned))). Servers that verify signatures will kick you while it's loaded.",
                             files: unsigned))
        }

        if !unreadableSignatures.isEmpty {
            out.append(.init(kind: .unreadableSignature, severity: .warning,
                             message: "\(unreadableSignatures.count) signature file\(unreadableSignatures.count == 1 ? " is" : "s are") damaged (\(sample(unreadableSignatures))). Verify the download by unsubscribing and resubscribing.",
                             files: unreadableSignatures))
        }

        // Invalid only when no other signature of the same PBO is good (servers accept any one trusted signature).
        let invalid = r.pbos.filter { p in
            p.signatures.contains { $0.verdict == .invalid } && !p.signatures.contains { $0.verdict == .valid || $0.verdict == .unverified }
        }
        if !invalid.isEmpty {
            let one = invalid.count == 1
            out.append(.init(kind: .invalidSignature, severity: .warning,
                             message: "\(invalid.count) addon file\(one ? " was" : "s were") changed after \(one ? "it was" : "they were") signed (\(sample(invalid.map(\.name)))), so \(one ? "its signature no longer matches" : "their signatures no longer match"). Servers that verify signatures will kick you with \"wrong signature\" until the author re-signs \(one ? "it" : "them").",
                             files: invalid.map(\.name)))
        }

        // Key bookkeeping, per distinct signer key (authority + key material).
        let shippedIDs = Set(shipped.map(\.keyID))
        let shippedByName = Dictionary(grouping: shipped, by: { $0.authority.lowercased() })
        var byKey: [String: (authority: String, pbos: [String])] = [:]
        for p in r.pbos {
            for s in p.signatures where s.verdict != .unreadable {
                byKey[s.keyID, default: (s.authority, [])].pbos.append(p.name)
            }
        }
        for (id, v) in byKey.sorted(by: { $0.key < $1.key }) where !shippedIDs.contains(id) {
            let pbos = Array(Set(v.pbos)).sorted()
            if let same = shippedByName[v.authority.lowercased()] {
                out.append(.init(kind: .keyMismatch, severity: .warning,
                                 message: "\(pbos.count) addon file\(pbos.count == 1 ? " is" : "s are") signed by \"\(v.authority)\", but the included \(same[0].authority).bikey is a different key, so servers using it will kick you (\(sample(pbos))).",
                                 files: pbos))
            } else {
                out.append(.init(kind: .keyNotShipped, severity: .info,
                                 message: "Signed by \"\(v.authority)\", but that key isn't included in the mod; server admins need it from elsewhere (\(sample(pbos))).",
                                 files: pbos))
            }
        }

        // Same-named keys with different material are already reported as a mismatch above.
        if Set(byKey.values.map { $0.authority.lowercased() }).count > 1 {
            let counts = byKey.values.map { ($0.authority, Set($0.pbos).count) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            out.append(.init(kind: .multipleAuthorities, severity: .info,
                             message: "Its addon files are signed by \(byKey.count) different keys (\(counts.map { "\($0.0): \($0.1)" }.joined(separator: ", "))). Servers need every one of these keys.",
                             files: counts.map(\.0)))
        }
        return out.sorted { $0.severity > $1.severity }
    }
}

// MARK: - Verification

/// A PBO's header read byte-exact (names are hashed raw), with the stored SHA-1 trailer.
private struct RawPBO {
    struct Entry {
        let name: [UInt8]      // lowercased ASCII, `/` → `\`
        let packing: UInt32
        let originalSize: Int
        let size: Int
        let offset: Int
        var isEmpty: Bool { packing == PBOArchive.cprsMagic ? originalSize == 0 : size == 0 }
        var ext: String {
            guard let dot = name.lastIndex(of: 0x2E), !name[dot...].contains(0x5C) else { return "" }
            return String(decoding: name[(dot + 1)...], as: UTF8.self)
        }
    }

    let data: Data
    let entries: [Entry]          // archive order; a repeated name keeps its first entry, as signers do
    let sorted: [Entry]           // by name bytes
    let prefix: [UInt8]?
    let checksum: [UInt8]?        // trailing SHA-1 of everything before it, when present
    let blobEnd: Int

    init?(url: URL) {
        guard let d = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        var r = ByteReader(d)
        var prefix: [UInt8]?
        var raw: [([UInt8], UInt32, Int, Int)] = []
        do {
            while true {
                let name = try r.cbytes()
                let packing = try r.u32(), original = try r.u32()
                _ = try r.u32(); _ = try r.u32()
                let size = try r.u32()
                if name.isEmpty && packing == PBOArchive.versMagic {
                    while true {
                        let key = try r.cbytes()
                        if key.isEmpty { break }
                        let value = try r.cbytes()
                        if String(decoding: key, as: UTF8.self).lowercased() == "prefix" { prefix = value }
                    }
                    continue
                }
                if name.isEmpty { break }
                raw.append((name.map { $0 == 0x2F ? 0x5C : ($0 >= 0x41 && $0 <= 0x5A ? $0 + 32 : $0) }, packing, Int(original), Int(size)))
            }
        } catch { return nil }
        var offset = r.i
        var list: [Entry] = []
        for (name, packing, original, size) in raw {
            list.append(Entry(name: name, packing: packing, originalSize: original, size: size, offset: offset))
            offset += size
        }
        guard offset <= d.count else { return nil }
        data = d
        var seen = Set<[UInt8]>()
        entries = list.filter { seen.insert($0.name).inserted }
        sorted = entries.sorted { $0.name.lexicographicallyPrecedes($1.name) }
        self.prefix = prefix
        blobEnd = offset
        if d.count >= offset + 21, d[d.startIndex + offset] == 0 {
            checksum = [UInt8](d[(d.startIndex + offset + 1)..<(d.startIndex + offset + 21)])
        } else {
            checksum = nil
        }
    }

    /// Stored bytes: signatures hash compressed entries as stored, not decompressed.
    private func stored(_ e: Entry) -> Data {
        data[(data.startIndex + e.offset)..<(data.startIndex + e.offset + e.size)]
    }

    private var nameHash: [UInt8] {
        var h = SHA1()
        for e in sorted where !e.isEmpty { h.update(e.name) }
        return h.finalize()
    }

    private static let v3Extensions: Set<String> = ["bikb", "cfg", "ext", "fsm", "h", "hpp", "inc", "sqf", "sqfc", "sqm", "sqs"]
    private static let v2Excluded: Set<String> = ["fxy", "jpg", "lip", "ogg", "p3d", "paa", "pac", "png", "rtm", "rvmat", "tga", "wrp", "wss"]

    /// Content hash covered by the third signature. v3 hashes script/config files; v2 hashes
    /// everything except media. Empty files don't count (a PBO whose only script is an empty
    /// .hpp hashes as "nothing"). Signers hash in archive order (some tools sort first), so the caller tries both.
    private func fileHash(version: UInt32, archiveOrder: Bool) -> [UInt8] {
        var h = SHA1()
        var nothing = true
        for e in archiveOrder ? entries : sorted where !e.isEmpty {
            let ext = e.ext
            let include = version >= 3 ? RawPBO.v3Extensions.contains(ext) : !RawPBO.v2Excluded.contains(ext)
            guard include else { continue }
            nothing = false
            h.update(stored(e))
        }
        if nothing { h.update(Array((version >= 3 ? "gnihton" : "nothing").utf8)) }
        return h.finalize()
    }

    private func combined(_ first: [UInt8], _ names: [UInt8]) -> [UInt8] {
        var h = SHA1()
        h.update(first)
        h.update(names)
        if let prefix, !prefix.isEmpty {
            h.update(prefix)
            if prefix.last != 0x5C { h.update([0x5C]) }
        }
        return h.finalize()
    }

    /// SHA-1 of everything before the trailer, computed from the bytes on disk.
    private var computedArchiveHash: [UInt8] {
        var h = SHA1()
        h.update(data[data.startIndex..<(data.startIndex + blobEnd)])
        return h.finalize()
    }

    /// Whether the archive is what the first signature covers: its stored trailer matches, or (for tools
    /// that write a different trailer than they signed) the hash of its bytes does. Hashing the whole
    /// file only happens when the trailer doesn't match.
    private func matchesArchiveHash(_ signed: [UInt8]) -> Bool {
        if let checksum, RSA.matches(signed, checksum) { return true }
        return RSA.matches(signed, computedArchiveHash)
    }

    /// Checks all three signed hashes. Only a mismatch of the first (the whole archive) proves the
    /// PBO changed after signing; if it matches, the bytes are what the signer hashed, so any later
    /// mismatch is Kitbag failing to reproduce the signer's hashing and must not be reported.
    func verify(_ s: BISignature) -> (SignatureReport.Verdict, String?) {
        let key = s.key
        guard let d1 = RSA.decrypt(s.sig1, key), let d2 = RSA.decrypt(s.sig2, key), let d3 = RSA.decrypt(s.sig3, key),
              RSA.isPadded(d1), RSA.isPadded(d2), RSA.isPadded(d3) else {
            return (.invalid, "signature doesn't decode with its own key")
        }
        let names = nameHash
        let unchanged = matchesArchiveHash(d1)
        let listOK = RSA.matches(d2, combined(RSA.digest(of: d1), names))
        let filesOK = [true, false].contains { RSA.matches(d3, combined(fileHash(version: s.version, archiveOrder: $0), names)) }
        if unchanged {
            return listOK && filesOK ? (.valid, nil) : (.unverified, listOK ? "file hash not reproduced" : "name hash not reproduced")
        }
        var what = ["repacked after signing"]
        if !listOK { what.append("file list differs") }
        if !filesOK { what.append("scripts differ") }
        return (.invalid, what.joined(separator: ", "))
    }
}

/// Textbook RSA public-key operation (Montgomery multiplication over 32-bit limbs), just enough
/// to check BI's PKCS#1 v1.5 SHA-1 signatures.
private enum RSA {
    /// `signature ^ e mod n` as big-endian bytes, nil when the key or signature is malformed.
    static func decrypt(_ sigLE: [UInt8], _ key: BIPublicKey) -> [UInt8]? {
        let n = limbs(key.modulus)
        guard n.count > 1, n[0] & 1 == 1, let top = n.last, top != 0 else { return nil }
        let base = limbs(sigLE, count: n.count)
        guard !greaterOrEqual(base, n) else { return nil }
        let k = n.count

        var inv: UInt32 = 1                                       // n[0]^-1 mod 2^32 (Newton)
        for _ in 0..<5 { inv = inv &* (2 &- n[0] &* inv) }
        let n0 = 0 &- inv

        func mul(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
            var t = [UInt32](repeating: 0, count: k + 2)
            for i in 0..<k {
                var c: UInt64 = 0
                let bi = UInt64(b[i])
                for j in 0..<k {
                    let s = UInt64(t[j]) + UInt64(a[j]) * bi + c
                    t[j] = UInt32(truncatingIfNeeded: s); c = s >> 32
                }
                var s = UInt64(t[k]) + c
                t[k] = UInt32(truncatingIfNeeded: s); t[k + 1] = UInt32(s >> 32)
                let m = UInt64(t[0] &* n0)
                s = UInt64(t[0]) + m * UInt64(n[0]); c = s >> 32
                for j in 1..<k {
                    s = UInt64(t[j]) + m * UInt64(n[j]) + c
                    t[j - 1] = UInt32(truncatingIfNeeded: s); c = s >> 32
                }
                s = UInt64(t[k]) + c
                t[k - 1] = UInt32(truncatingIfNeeded: s)
                t[k] = t[k + 1] &+ UInt32(s >> 32)
            }
            var out = Array(t[0..<k])
            if t[k] != 0 || greaterOrEqual(out, n) { subtract(&out, n) }
            return out
        }

        var r2 = [UInt32](repeating: 0, count: k)                 // R^2 mod n by doubling 1
        r2[0] = 1
        for _ in 0..<(64 * k) {
            var carry: UInt32 = 0
            for j in 0..<k { let v = r2[j]; r2[j] = (v << 1) | carry; carry = v >> 31 }
            if carry != 0 || greaterOrEqual(r2, n) { subtract(&r2, n) }
        }
        let bm = mul(base, r2)
        var x = bm
        let e = key.exponent
        guard e > 1 else { return nil }
        for bit in stride(from: 31 - e.leadingZeroBitCount - 1, through: 0, by: -1) {
            x = mul(x, x)
            if e & (1 << UInt32(bit)) != 0 { x = mul(x, bm) }
        }
        var one = [UInt32](repeating: 0, count: k); one[0] = 1
        x = mul(x, one)

        var be: [UInt8] = []
        be.reserveCapacity(k * 4)
        for limb in x.reversed() { for s in stride(from: 24, through: 0, by: -8) { be.append(UInt8(truncatingIfNeeded: limb >> UInt32(s))) } }
        return Array(be.suffix(key.bits / 8))
    }

    /// PKCS#1 v1.5 block `00 01 FF… 00 <SHA-1 DigestInfo> <hash>` compared byte for byte.
    static func matches(_ block: [UInt8], _ hash: [UInt8]) -> Bool {
        let info: [UInt8] = [0x00, 0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2B, 0x0E, 0x03, 0x02, 0x1A, 0x05, 0x00, 0x04, 0x14]
        guard block.count >= 38 + 20 else { return false }
        var expected: [UInt8] = [0x00, 0x01] + [UInt8](repeating: 0xFF, count: block.count - 38) + info
        expected += hash
        return block == expected
    }

    /// Whether a decoded block has PKCS#1 v1.5 SHA-1 structure (any hash).
    static func isPadded(_ block: [UInt8]) -> Bool { matches(block, digest(of: block)) }

    /// The hash carried by a decoded block (its last 20 bytes).
    static func digest(of block: [UInt8]) -> [UInt8] { Array(block.suffix(20)) }

    private static func limbs(_ le: [UInt8], count: Int? = nil) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: count ?? (le.count + 3) / 4)
        for (i, b) in le.enumerated() where i / 4 < out.count { out[i / 4] |= UInt32(b) << UInt32(8 * (i % 4)) }
        if count == nil { while out.count > 1 && out.last == 0 { out.removeLast() } }
        return out
    }

    private static func greaterOrEqual(_ a: [UInt32], _ b: [UInt32]) -> Bool {
        for i in stride(from: max(a.count, b.count) - 1, through: 0, by: -1) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }

    private static func subtract(_ a: inout [UInt32], _ b: [UInt32]) {
        var borrow: UInt64 = 0
        for i in 0..<a.count {
            let y = UInt64(i < b.count ? b[i] : 0) + borrow
            let x = UInt64(a[i])
            a[i] = UInt32(truncatingIfNeeded: x &- y)
            borrow = x < y ? 1 : 0
        }
    }
}

/// Streaming SHA-1 (FIPS 180-4), used only to recompute signature hashes.
struct SHA1 {
    private var h: (UInt32, UInt32, UInt32, UInt32, UInt32) = (0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0)
    private var pending: [UInt8] = []
    private var total: UInt64 = 0

    mutating func update(_ bytes: [UInt8]) { bytes.withUnsafeBytes { update($0) } }
    mutating func update(_ data: Data) { data.withUnsafeBytes { update($0) } }

    mutating func update(_ buf: UnsafeRawBufferPointer) {
        guard let base = buf.baseAddress, buf.count > 0 else { return }
        total += UInt64(buf.count)
        var i = 0
        if !pending.isEmpty {
            let take = min(64 - pending.count, buf.count)
            pending.append(contentsOf: UnsafeRawBufferPointer(rebasing: buf[0..<take]))
            i = take
            if pending.count == 64 {
                let block = pending
                block.withUnsafeBytes { compress($0.baseAddress!) }
                pending.removeAll(keepingCapacity: true)
            }
        }
        while i + 64 <= buf.count { compress(base + i); i += 64 }
        if i < buf.count { pending.append(contentsOf: UnsafeRawBufferPointer(rebasing: buf[i...])) }
    }

    mutating func finalize() -> [UInt8] {
        let bits = total &* 8
        var tail: [UInt8] = [0x80]
        tail += [UInt8](repeating: 0, count: (119 - (Int(total % 64))) % 64)
        for s in stride(from: 56, through: 0, by: -8) { tail.append(UInt8(truncatingIfNeeded: bits >> UInt64(s))) }
        let saved = total
        update(tail)
        total = saved
        var out: [UInt8] = []
        for v in [h.0, h.1, h.2, h.3, h.4] { for s in stride(from: 24, through: 0, by: -8) { out.append(UInt8(truncatingIfNeeded: v >> UInt32(s))) } }
        return out
    }

    private mutating func compress(_ p: UnsafeRawPointer) {
        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 80) { w in
            for t in 0..<16 {
                let b = p + t * 4
                w[t] = UInt32(b.load(as: UInt8.self)) << 24 | UInt32(b.load(fromByteOffset: 1, as: UInt8.self)) << 16
                    | UInt32(b.load(fromByteOffset: 2, as: UInt8.self)) << 8 | UInt32(b.load(fromByteOffset: 3, as: UInt8.self))
            }
            for t in 16..<80 {
                let v = w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16]
                w[t] = v << 1 | v >> 31
            }
            var (a, b, c, d, e) = h
            for t in 0..<80 {
                let f: UInt32, k: UInt32
                switch t {
                case 0..<20: f = (b & c) | (~b & d); k = 0x5A82_7999
                case 20..<40: f = b ^ c ^ d; k = 0x6ED9_EBA1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1B_BCDC
                default: f = b ^ c ^ d; k = 0xCA62_C1D6
                }
                let temp = (a << 5 | a >> 27) &+ f &+ e &+ k &+ w[t]
                e = d; d = c; c = b << 30 | b >> 2; b = a; a = temp
            }
            h = (h.0 &+ a, h.1 &+ b, h.2 &+ c, h.3 &+ d, h.4 &+ e)
        }
    }
}
