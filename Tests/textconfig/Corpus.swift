// Real-library validation: every text config.cpp in every loaded PBO of the Workshop mods,
// preprocessed against a VFS of all loaded mod + vanilla PBOs, parsed, and compared with v1.
import Foundation

enum Corpus {
    static let steam = "\(NSHomeDirectory())/Library/Application Support/Steam/steamapps"
    static let workshop = URL(fileURLWithPath: steam + "/workshop/content/107410")
    static let game = URL(fileURLWithPath: steam + "/common/Arma 3")

    struct Job { let mod: String; let archive: PBOArchive; let entry: PBOEntry }
    struct Result {
        var path = ""
        var mod = ""
        var diagnostics: [String] = []
        var hasIncludes: [String] = []
        var parseError: String?
        var v2: [PatchInfo] = []
        var v1: [String: [String]] = [:]
        var raw = ""
        var preprocessed = ""
        var seconds = 0.0
        var siblingBin = false
        var archiveFile = ""
        var prefix = ""
        var tree: ConfigClass?
        var bin: ConfigClass?
        var binError: String?
    }

    static func modName(_ dir: URL) -> String {
        for f in ["meta.cpp", "mod.cpp"] {
            let u = dir.appendingPathComponent(f)
            if let t = (try? String(contentsOf: u, encoding: .utf8)) ?? (try? String(contentsOf: u, encoding: .isoLatin1)),
               let r = t.range(of: #"name\s*=\s*"([^"]*)""#, options: .regularExpression) {
                return String(t[r]).replacingOccurrences(of: #"^name\s*=\s*""#, with: "", options: .regularExpression).dropLast().description
            }
        }
        return dir.lastPathComponent
    }

    /// Mod PBOs (by Workshop ID) and vanilla PBOs, as Arma would load them.
    static func load() -> (mods: [(id: String, name: String, archives: [PBOArchive])], vanilla: [PBOArchive], failed: [String]) {
        let fm = FileManager.default
        var failed: [String] = []
        func open(_ urls: [URL]) -> [PBOArchive] {
            urls.compactMap { u in
                do { return try PBOArchive(url: u) } catch { failed.append("\(u.path): \(error)"); return nil }
            }
        }
        let ids = ((try? fm.contentsOfDirectory(atPath: workshop.path)) ?? []).filter { Int($0) != nil }.sorted()
        let mods = ids.map { id -> (String, String, [PBOArchive]) in
            let dir = workshop.appendingPathComponent(id)
            return (id, modName(dir), open(loadedPBOs(in: dir)))
        }
        var vanillaURLs = loadedPBOs(in: game)
        for sub in ((try? fm.contentsOfDirectory(at: game, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []).sorted(by: { $0.path < $1.path }) {
            let v = try? sub.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let n = sub.lastPathComponent
            guard v?.isDirectory == true, v?.isSymbolicLink != true, !n.hasPrefix("@"), !n.hasSuffix(".app"), Int(n) == nil else { continue }
            vanillaURLs += loadedPBOs(in: sub)
        }
        let dta = game.appendingPathComponent("Dta")
        vanillaURLs += ((try? fm.contentsOfDirectory(at: dta, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension.lowercased() == "pbo" }
        return (mods, open(vanillaURLs), failed)
    }

    static func fileName(_ p: String) -> String { String(p.split(separator: "\\").last ?? "") }

    static func dump(_ path: String) {
        let (mods, vanilla, _) = load()
        let vfs = VirtualFileSystem(archives: mods.flatMap(\.archives) + vanilla)
        guard let text = vfs.read(path) else { print("not found: \(path)"); return }
        let r = ConfigPreprocessor(vfs: vfs).process(text, path: path)
        // Directives and comments leave blank lines behind; skip them so the output is readable.
        print(r.text.split(separator: "\n").filter { !$0.allSatisfy(\.isWhitespace) }.joined(separator: "\n"))
        print("---- diagnostics: \(r.diagnostics)\n---- has_include: \(r.usedHasInclude)")
        do { let root = try TextConfigParser.parse(r.text); print("---- patches: \(PatchInfo.extract(from: root))") }
        catch { print("---- parse error: \(error)") }
    }

    static func run() {
        let t0 = Date()
        let (mods, vanilla, failed) = load()
        let modArchives = mods.flatMap(\.archives)
        let vfs = VirtualFileSystem(archives: modArchives + vanilla)
        let tLoad = Date().timeIntervalSince(t0)
        print("archives: \(modArchives.count) mod PBOs in \(mods.count) mods, \(vanilla.count) vanilla PBOs, \(failed.count) unreadable; index \(String(format: "%.2f", tLoad))s")
        for f in failed { print("  unreadable: \(f)") }

        var jobs: [Job] = []
        for m in mods { for a in m.archives { for e in a.entries where fileName(e.path) == "config.cpp" { jobs.append(Job(mod: m.id, archive: a, entry: e)) } } }
        let names = Dictionary(uniqueKeysWithValues: mods.map { ($0.id, $0.name) })

        let pp = ConfigPreprocessor(vfs: vfs)
        var results = [Result](repeating: Result(), count: jobs.count)
        let t1 = Date()
        results.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: jobs.count) { k in
                let j = jobs[k]
                var r = Result()
                r.mod = j.mod
                r.path = VirtualFileSystem.path(of: j.entry, in: j.archive)
                let dir = j.entry.path.split(separator: "\\").dropLast().joined(separator: "\\")
                let binEntry = j.archive.entry(dir.isEmpty ? "config.bin" : dir + "\\config.bin")
                r.siblingBin = binEntry != nil
                r.archiveFile = j.archive.url.deletingPathExtension().lastPathComponent.lowercased()
                r.prefix = j.archive.prefix
                guard let data = j.archive.contents(of: j.entry) else { r.parseError = "unreadable entry"; buf[k] = r; return }
                let s = Date()
                r.raw = VirtualFileSystem.decode(data)
                let out = pp.process(r.raw, path: r.path)
                r.diagnostics = out.diagnostics
                r.hasIncludes = out.usedHasInclude
                r.preprocessed = out.text
                do { let t = try TextConfigParser.parse(out.text); r.tree = t; r.v2 = PatchInfo.extract(from: t) }
                catch { r.parseError = "\(error)" }
                r.seconds = Date().timeIntervalSince(s)
                r.v1 = V1Text.text(data)
                if let b = binEntry, let bd = j.archive.contents(of: b) {
                    do { r.bin = try RapParser.parse(bd) } catch { r.binError = "\(error)" }
                }
                buf[k] = r
            }
        }
        let tRun = Date().timeIntervalSince(t1)
        let bytes = results.reduce(0) { $0 + $1.raw.utf8.count }
        print("\nprocessed \(results.count) text config.cpp files from \(Set(results.map(\.mod)).count) mods (\(bytes / 1024) KiB) in \(String(format: "%.2f", tRun))s wall, \(String(format: "%.2f", results.reduce(0) { $0 + $1.seconds }))s CPU in preprocess+parse")
        print("  \(results.filter(\.siblingBin).count) of them sit next to a config.bin (the game prefers the .bin)")
        for r in results.sorted(by: { $0.seconds > $1.seconds }).prefix(3) { print("  slowest: \(String(format: "%.3f", r.seconds))s \(r.path)") }

        // Diagnostics by kind.
        var byKind: [String: [(String, String)]] = [:]
        for r in results { for d in r.diagnostics { byKind[String(d.prefix { $0 != ":" }), default: []].append((r.path, d)) } }
        print("\ndiagnostics: \(byKind.values.reduce(0) { $0 + $1.count }) in \(results.filter { !$0.diagnostics.isEmpty }.count) files")
        for (kind, list) in byKind.sorted(by: { $0.value.count > $1.value.count }) {
            print("  \(kind): \(list.count) in \(Set(list.map(\.0)).count) files")
            var seen = Set<String>()
            for (p, d) in list where seen.insert(d).inserted && seen.count <= 8 { print("    \(d)  [\(names[results.first { $0.path == p }!.mod] ?? "")]") }
        }
        // Zero diagnostics must not mean "diagnostics never fire": against an empty file system the same files
        // have to report their includes as unresolved.
        let includeRE = try! NSRegularExpression(pattern: #"(?m)^[ \t]*#[ \t]*include[ \t]*["<]"#)
        let withIncludes = results.filter { includeRE.firstMatch(in: $0.raw, range: NSRange($0.raw.startIndex..., in: $0.raw)) != nil }
        let emptyPP = ConfigPreprocessor(vfs: VirtualFileSystem(archives: []))
        let unresolvedWithoutVFS = withIncludes.filter { emptyPP.process($0.raw, path: $0.path).diagnostics.contains { $0.hasPrefix("unresolved include") } }.count
        print("  sanity: \(withIncludes.count) of \(results.count) files contain #include; with an empty file system \(unresolvedWithoutVFS) of them report 'unresolved include'")
        let hasIncl = results.filter { !$0.hasIncludes.isEmpty }
        let hasPaths = Set(hasIncl.flatMap(\.hasIncludes))
        print("  files using __has_include: \(hasIncl.count) (\(hasPaths.count) distinct paths, \(hasPaths.filter { vfs.exists($0) }.count) present in the library)")
        for r in hasIncl { print("    \(r.path) [\(names[r.mod] ?? "")]: " + r.hasIncludes.map { "\($0)=\(vfs.exists($0) ? "yes" : "no")" }.prefix(6).joined(separator: " ")) }

        // Parse failures.
        let failures = results.filter { $0.parseError != nil }
        print("\nparse failures: \(failures.count)")
        for r in failures {
            print("  \(r.path) [\(names[r.mod] ?? r.mod)]: \(r.parseError!)")
            if let m = r.parseError?.range(of: #"^line (\d+)"#, options: .regularExpression),
               let n = Int(r.parseError![m].dropFirst(5)) {
                let lines = r.preprocessed.components(separatedBy: "\n")
                for k in max(1, n - 3)...min(lines.count, n + 1) { print("     \(k == n ? ">" : " ")\(k): \(lines[k - 1].prefix(160))") }
            }
        }

        // Totals and ALiVE.
        let v2Names = results.flatMap { r in r.v2.map { ($0.name, r.path) } }
        print("\nCfgPatches: v2 \(v2Names.count) entries (\(Set(v2Names.map(\.0)).count) distinct), v1 \(results.reduce(0) { $0 + $1.v1.count }) entries")
        print("files with no CfgPatches: v2 \(results.filter { $0.v2.isEmpty && $0.parseError == nil }.count), v1 \(results.filter { $0.v1.isEmpty }.count)")
        for r in results where r.path.hasPrefix("x\\alive\\addons\\main\\") {
            print("ALiVE \(r.path): \(r.v2.map { "\($0.name) requiredAddons=\($0.requiredAddons) requiredVersion=\($0.requiredVersion.map { String($0) } ?? "nil")" }) | v1 \(r.v1)")
        }

        // Files where v2 found no CfgPatches: legitimate (patch-less helper configs) or a silent failure?
        let empties = results.filter { $0.v2.isEmpty && $0.parseError == nil }
        print("\nfiles without a v2 CfgPatches class: \(empties.count)")
        for r in empties where r.v1.isEmpty || true {
            print("  \(r.path) [\(names[r.mod] ?? "")] raw mentions CfgPatches: \(r.raw.lowercased().contains("cfgpatches")), preprocessed: \(r.preprocessed.lowercased().contains("cfgpatches")), bytes \(r.raw.utf8.count)")
        }
        // Sanity of the addon names themselves: macro leftovers would show up as odd characters or bare macro words.
        let oddNames = v2Names.filter { $0.0.range(of: #"^[a-z0-9_.\-]+$"#, options: .regularExpression) == nil || ["addon", "component", "prefix"].contains($0.0) || $0.0.isEmpty }
        print("odd-looking addon names: \(oddNames.count)")
        for (n, p) in oddNames.prefix(20) { print("  '\(n)' in \(p)") }
        // Plausibility of macro-built names: they normally equal the PBO file name or `<mod>_<component>` from the prefix.
        // Anything else is listed so each can be judged against its source.
        var plausible = 0
        var implausible: [(String, Result)] = []
        for r in results where r.siblingBin == false {
            for p in r.v2 {
                let likely: Set<String> = {
                    var s: Set<String> = [r.archiveFile]
                    let parts = r.prefix.split(separator: "\\").map(String.init)
                    if let l = parts.last { s.insert(l) }
                    if let a = parts.firstIndex(of: "addons"), a > 0, let l = parts.last { s.insert(parts[a - 1] + "_" + l) }
                    return s
                }()
                if likely.contains(p.name) || r.raw.lowercased().contains("class " + p.name) { plausible += 1 } else { implausible.append((p.name, r)) }
            }
        }
        print("addon names of configs without a config.bin: \(plausible) match the PBO name, the prefix or are written literally; \(implausible.count) do not")
        for (n, r) in implausible.prefix(40) { print("  '\(n)' in \(r.path) (pbo \(r.archiveFile), prefix '\(r.prefix)') [\(names[r.mod] ?? "")]") }
        let dupNames = Dictionary(grouping: v2Names, by: \.0).filter { Set($0.value.map(\.1)).count > 1 }
        print("addon names defined by more than one file: \(dupNames.count)")

        // v1 vs v2.
        var onlyV2: [(String, Result)] = [], onlyV1: [(String, Result)] = [], reqDiff: [(String, [String], [String], Result)] = []
        for r in results {
            let a = Set(r.v2.map(\.name)), b = Set(r.v1.keys)
            for n in a.subtracting(b).sorted() { onlyV2.append((n, r)) }
            for n in b.subtracting(a).sorted() { onlyV1.append((n, r)) }
            for p in r.v2 where b.contains(p.name) {
                let v1req = r.v1[p.name]!
                let v2req = p.skipWhenMissingDependencies ? [] : p.requiredAddons
                if Set(v1req) != Set(v2req) { reqDiff.append((p.name, v1req, v2req, r)) }
            }
        }
        func reason2(_ n: String, _ r: Result) -> String {
            let raw = r.raw.lowercased()
            let stripped = raw.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"//[^\n]*"#, with: "", options: .regularExpression)
            if stripped.range(of: #"class\s+cfgpatches\s*\{"#, options: .regularExpression) == nil {
                return stripped.contains("#include") ? "CfgPatches lives in an #include'd file (v1 reads config.cpp only)" : "no literal 'class CfgPatches {' (other format)"
            }
            if stripped.range(of: "class\\s+" + NSRegularExpression.escapedPattern(for: n) + "\\b", options: .regularExpression) == nil {
                return "class name is a macro (ADDON, …) or built by one"
            }
            return "name present literally, v1 still missed it"
        }
        print("\nv2-only addon names: \(onlyV2.count) in \(Set(onlyV2.map(\.1.path)).count) files")
        for (reason, list) in Dictionary(grouping: onlyV2, by: { reason2($0.0, $0.1) }).sorted(by: { $0.value.count > $1.value.count }) {
            let shown = ProcessInfo.processInfo.environment["CORPUS_FULL"] != nil ? list.count : 25
            print("  [\(reason)] \(list.count): " + list.prefix(shown).map { "\($0.0) (\(names[$0.1.mod] ?? "")\(list.count < 5 ? ", " + $0.1.path : ""))" }.joined(separator: ", ") + (list.count > shown ? " …" : ""))
        }
        print("v1-only addon names: \(onlyV1.count)")
        for (n, r) in onlyV1 { print("  \(n) in \(r.path) [\(names[r.mod] ?? "")] parseError=\(r.parseError ?? "-")") }
        print("same name, different requiredAddons (v1 → v2): \(reqDiff.count)")
        for (n, a, b, r) in reqDiff.prefix(40) {
            print("  \(n) [\(names[r.mod] ?? "")]: -\(Set(a).subtracting(b).sorted()) +\(Set(b).subtracting(a).sorted())")
        }
        CrossCheck.report(results, names: names)
        print("\ntotal \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
    }
}
