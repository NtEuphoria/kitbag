// Signature harness: SHA-1 vectors, then Signatures.check on every installed Workshop mod.
// Usage: run [workshopDir] [--fast] [--only <id>]
import Foundation

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
func sha(_ s: String) -> String { var h = SHA1(); h.update(Array(s.utf8)); return hex(h.finalize()) }

// FIPS 180 test vectors.
let vectors: [(String, String)] = [
    ("", "da39a3ee5e6b4b0d3255bfef95601890afd80709"),
    ("abc", "a9993e364706816aba3e25717850c26c9cd0d89d"),
    ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", "84983e441c3bd26ebaae4aa1f95129e5e54670f1"),
    (String(repeating: "a", count: 1_000_000), "34aa973cd4c4daa4f61eeb2bdbad27316534016f"),
]
for (input, expected) in vectors {
    let got = sha(input)
    print(got == expected ? "sha1 ok" : "SHA1 FAIL len \(input.count): \(got)")
}
var split = SHA1()   // streaming across odd chunk sizes
let big = Array(String(repeating: "a", count: 1_000_000).utf8)
var i = 0, step = 1
while i < big.count { let n = min(step, big.count - i); split.update(Array(big[i..<(i + n)])); i += n; step = step % 97 + 13 }
print(hex(split.finalize()) == vectors[3].1 ? "sha1 streaming ok" : "SHA1 STREAMING FAIL")

let args = CommandLine.arguments
let workshop = URL(fileURLWithPath: args.count > 1 && !args[1].hasPrefix("--") ? args[1]
    : "\(NSHomeDirectory())/Library/Application Support/Steam/steamapps/workshop/content/107410")

// Mutation tests: copy the smallest validly signed PBO of the library into a scratch mod and damage it
// in known ways; the report must change in exactly the expected way.
if args.contains("--mutate") {
    let fm = FileManager.default
    var best: (url: URL, size: Int)?
    for m in (try? fm.contentsOfDirectory(at: workshop, includingPropertiesForKeys: nil)) ?? [] {
        let r = Signatures.check(modFolder: m)
        guard r.pbos.count == 1, r.findings.isEmpty, r.pbos[0].signatures.count == 1, r.pbos[0].signatures[0].version == 3,
              let pbo = loadedPBOs(in: m).first, let size = (try? fm.attributesOfItem(atPath: pbo.path)[.size]) as? Int else { continue }
        if best == nil || size < best!.size { best = (m, size) }
    }
    guard let src = best?.url else { print("no suitable mod"); exit(1) }
    print("mutating a copy of \(src.lastPathComponent) (\(best!.size) bytes)")
    var failures = 0
    func expect(_ ok: Bool, _ what: String) { print(ok ? "ok   \(what)" : "FAIL \(what)"); if !ok { failures += 1 } }

    func scratch(_ body: (URL, URL, URL, URL?) throws -> Void) rethrows {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kitbag-sig-\(UUID().uuidString)")
        let addons = root.appendingPathComponent("addons")
        try? fm.createDirectory(at: addons, withIntermediateDirectories: true)
        for f in (try? fm.contentsOfDirectory(at: loadedPBOs(in: src)[0].deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? [] {
            try? fm.copyItem(at: f, to: addons.appendingPathComponent(f.lastPathComponent))
        }
        for k in Signatures.keyFiles(in: src) { try? fm.copyItem(at: k, to: root.appendingPathComponent(k.lastPathComponent)) }
        let pbo = loadedPBOs(in: root)[0]
        let sig = (try? fm.contentsOfDirectory(at: addons, includingPropertiesForKeys: nil))?.first { $0.pathExtension == "bisign" }
        defer { try? fm.removeItem(at: root) }
        try body(root, pbo, addons, sig)
    }
    func patch(_ url: URL, _ edit: (inout Data) -> Void) {
        guard var d = try? Data(contentsOf: url) else { return }
        edit(&d)
        try? d.write(to: url)
    }

    scratch { root, pbo, _, _ in
        let r = Signatures.check(modFolder: root)
        expect(r.findings.isEmpty && r.pbos[0].signatures[0].verdict == .valid, "clean copy is valid with no findings: \(r.findings.map(\.kind))")
    }
    scratch { root, pbo, _, _ in
        patch(pbo) { $0[$0.count - 1] ^= 0xFF }          // damage only the trailer
        let r = Signatures.check(modFolder: root)
        expect(r.pbos[0].signatures[0].verdict == .valid, "wrong trailer but intact bytes stays valid: \(r.pbos[0].signatures[0].verdict)")
    }
    scratch { root, pbo, _, _ in
        patch(pbo) { $0[$0.count - 1] ^= 0xFF; $0[$0.count - 30] ^= 0xFF }   // damage trailer and content
        let r = Signatures.check(modFolder: root)
        expect(r.pbos[0].signatures[0].verdict == .invalid && r.findings.contains { $0.kind == .invalidSignature }, "changed bytes are invalid: \(r.pbos[0].signatures[0].verdict)")
    }
    scratch { root, _, _, sig in
        try? fm.removeItem(at: sig!)
        let r = Signatures.check(modFolder: root)
        expect(r.findings.map(\.kind) == [.unsigned], "removed bisign is unsigned: \(r.findings.map(\.kind))")
    }
    scratch { root, _, _, sig in
        patch(sig!) { $0 = $0.prefix(100) }
        let r = Signatures.check(modFolder: root)
        expect(r.findings.map(\.kind) == [.unreadableSignature], "truncated bisign is unreadable only: \(r.findings.map(\.kind))")
    }
    scratch { root, _, _, _ in
        for k in Signatures.keyFiles(in: root) { try? fm.removeItem(at: k) }
        let r = Signatures.check(modFolder: root)
        expect(r.findings.map(\.kind) == [.keyNotShipped] && r.findings[0].severity == .info, "missing bikey: \(r.findings.map(\.kind))")
    }
    print(failures == 0 ? "all mutation checks passed" : "\(failures) mutation checks FAILED")
    exit(failures == 0 ? 0 : 1)
}
let verify = !args.contains("--fast")
let only = args.firstIndex(of: "--only").map { args[$0 + 1] }

func modName(_ folder: URL) -> String {
    for f in ["meta.cpp", "mod.cpp"] {
        if let t = (try? String(contentsOf: folder.appendingPathComponent(f), encoding: .utf8)) ?? (try? String(contentsOf: folder.appendingPathComponent(f), encoding: .isoLatin1)),
           let r = t.range(of: #"name\s*=\s*"([^"]*)""#, options: .regularExpression) {
            let m = String(t[r])
            return String(m[m.index(after: m.firstIndex(of: "\"")!)...].dropLast())
        }
    }
    return folder.lastPathComponent
}

let mods = ((try? FileManager.default.contentsOfDirectory(at: workshop, includingPropertiesForKeys: nil)) ?? [])
    .filter { only == nil || $0.lastPathComponent == only }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
let start = Date()
var reports = [SignatureReport](repeating: SignatureReport(), count: mods.count)
reports.withUnsafeMutableBufferPointer { buf in
    DispatchQueue.concurrentPerform(iterations: mods.count) { buf[$0] = Signatures.check(modFolder: mods[$0], verify: verify) }
}
let elapsed = Date().timeIntervalSince(start)

var verdicts: [String: Int] = [:], versions: [Int: Int] = [:], kinds: [String: Int] = [:]
var pboTotal = 0, modsWithFindings = 0
for (m, r) in zip(mods, reports) {
    pboTotal += r.pbos.count
    for p in r.pbos { for s in p.signatures { verdicts[s.verdict.rawValue, default: 0] += 1; versions[s.version, default: 0] += 1 } }
    for f in r.findings { kinds["\(f.kind.rawValue)/\(f.severity)", default: 0] += 1 }
    if !r.findings.isEmpty { modsWithFindings += 1 }
    guard !r.findings.isEmpty || args.contains("--all") else { continue }
    print("\n\(m.lastPathComponent)  \(modName(m))  [\(r.pbos.count) pbo, keys: \(r.keys.map { "\($0.file)=\($0.keyID)" }.joined(separator: " "))]")
    for f in r.findings { print("  [\(f.severity)] \(f.kind.rawValue): \(f.message)") }
    for p in r.pbos { for s in p.signatures where s.verdict != .valid { print("    \(s.file) v\(s.version) \(s.keyID): \(s.verdict.rawValue) \(s.detail ?? "")") } }
}
print("\n== \(mods.count) mods, \(pboTotal) loaded PBOs, \(String(format: "%.1f", elapsed)) s, verify=\(verify)")
print("signature verdicts: \(verdicts.sorted { $0.key < $1.key })")
print("bisign versions: \(versions.sorted { $0.key < $1.key })")
print("findings: \(kinds.sorted { $0.key < $1.key })")
print("mods with findings: \(modsWithFindings)")
