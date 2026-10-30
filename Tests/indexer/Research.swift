// Evidence on the real library for the two loading rules the indexer implements:
//  1. a folder holding both config.cpp and config.bin uses config.cpp (BI wiki, "Config.cpp/bin File Format");
//  2. configs in sub-folders of a PBO are loaded as addons of their own (BI wiki, "CfgPatches" and the same page).
// The first can't be observed without running the game; the second can: the base game works, so classes it
// needs must be reachable, and any that only a nested config defines prove nested configs are loaded.
import Foundation

enum Research {
    struct Cfg { let pbo: String; let dir: String; let kind: String; let root: ConfigClass?; let isVanilla: Bool }

    static func defined(_ c: ConfigClass, _ path: String = "", into s: inout Set<String>) {
        for ch in c.children where !ch.isExternal {
            let p = path.isEmpty ? ch.name.lowercased() : path + "/" + ch.name.lowercased()
            s.insert(p)
            defined(ch, p, into: &s)
        }
    }

    static func run() {
        let t0 = Date()
        var cfgs: [Cfg] = []
        var bothFolders: [(pbo: String, dir: String, vanilla: Bool)] = []
        var pboCount = 0
        func scan(_ urls: [URL], vanilla: Bool) {
            for u in urls {
                guard let a = try? PBOArchive(url: u) else { continue }
                pboCount += 1
                var byDir: [String: [String: PBOEntry]] = [:]
                for e in a.entries {
                    let parts = e.path.split(separator: "\\", omittingEmptySubsequences: false)
                    guard let f = parts.last, f == "config.bin" || f == "config.cpp" else { continue }
                    byDir[parts.dropLast().joined(separator: "\\"), default: [:]][String(f)] = e
                }
                for (dir, kinds) in byDir {
                    if kinds.count == 2 { bothFolders.append((u.lastPathComponent, dir, vanilla)) }
                    for (k, e) in kinds {
                        var root: ConfigClass?
                        if k == "config.bin", let d = a.contents(of: e) { root = try? RapParser.parse(d) }
                        cfgs.append(Cfg(pbo: u.path, dir: dir, kind: k, root: root, isVanilla: vanilla))
                    }
                }
            }
        }
        scan(Real.modFolders().flatMap { loadedPBOs(in: $0) }, vanilla: false)
        scan(ConfigIndexer.vanillaPBOs(in: Real.game).map(\.url), vanilla: true)
        // Entries that share a name inside one PBO: does it matter which one is used?
        var dupPBOs = 0, dupDiffer = 0, dupExamples: [String] = []
        for u in Real.modFolders().flatMap({ loadedPBOs(in: $0) }) + ConfigIndexer.vanillaPBOs(in: Real.game).map(\.url) {
            guard let a = try? PBOArchive(url: u) else { continue }
            let configs = Dictionary(grouping: a.entries.filter { $0.path == "config.bin" || $0.path == "config.cpp" || $0.path.hasSuffix("\\config.bin") || $0.path.hasSuffix("\\config.cpp") }, by: \.path)
            var differs = false, dup = false
            for (_, list) in configs where list.count > 1 {
                dup = true
                let first = a.contents(of: list[0])
                if list.dropFirst().contains(where: { a.contents(of: $0) != first }) { differs = true }
            }
            if dup { dupPBOs += 1; if differs { dupDiffer += 1; dupExamples.append(u.lastPathComponent) } }
        }
        print("PBOs with duplicate config entries: \(dupPBOs), of which the copies differ in content: \(dupDiffer) \(dupExamples.prefix(5))")
        print("scanned \(pboCount) PBOs in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")

        for vanilla in [false, true] {
            let set = cfgs.filter { $0.isVanilla == vanilla }
            let nested = set.filter { !$0.dir.isEmpty }
            let bins = set.filter { $0.kind == "config.bin" }
            let nestedBins = nested.filter { $0.kind == "config.bin" }
            let noPatches = nestedBins.filter { $0.root?.child("CfgPatches") == nil }
            let depth = Dictionary(grouping: nested) { $0.dir.split(separator: "\\").count }
            print("\n\(vanilla ? "VANILLA" : "MODS"): \(set.count) config files (\(bins.count) .bin, \(set.count - bins.count) .cpp); nested \(nested.count) (by depth: \(depth.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value.count)" }.joined(separator: " ")))")
            print("  folders holding both config.cpp and config.bin: \(bothFolders.filter { $0.vanilla == vanilla }.count)")
            print("  nested config.bin without a CfgPatches class: \(noPatches.count) of \(nestedBins.count)")
        }

        // Does the nested config of a vanilla PBO carry classes that its root config lacks?
        let byPBO = Dictionary(grouping: cfgs.filter { $0.isVanilla && $0.kind == "config.bin" && $0.root != nil }, by: \.pbo)
        var withNested = 0, nestedOnlyClasses = 0, nestedTotal = 0, pbosWithNestedOnly = 0
        var definers: [String: [String]] = [:]
        let probes = ["cfgvehicles/b_soldier_f", "cfgweapons/arifle_mx_f", "cfgvehicles/b_mrap_01_f", "cfgvehicles/c_man_1"]
        var nestedNoPatchOnly = 0
        for (pbo, list) in byPBO {
            guard let root = list.first(where: { $0.dir.isEmpty }), list.contains(where: { !$0.dir.isEmpty }) else { continue }
            withNested += 1
            var rootSet = Set<String>(); defined(root.root!, into: &rootSet)
            var found = false
            for n in list where !n.dir.isEmpty {
                var s = Set<String>(); defined(n.root!, into: &s)
                nestedTotal += s.count
                let only = s.subtracting(rootSet)
                nestedOnlyClasses += only.count
                if !only.isEmpty { found = true }
                if n.root!.child("CfgPatches") == nil { nestedNoPatchOnly += only.count }
            }
            if found { pbosWithNestedOnly += 1 }
            for p in probes {
                var all = [(String, Set<String>)]([("", rootSet)])
                for n in list where !n.dir.isEmpty { var s = Set<String>(); defined(n.root!, into: &s); all.append((n.dir, s)) }
                for (d, s) in all where s.contains(p) { definers[p, default: []].append((pbo as NSString).lastPathComponent + (d.isEmpty ? " (root)" : " [\(d)]")) }
            }
        }
        print("\nVANILLA nested vs root: \(withNested) PBOs have a root config.bin and nested ones")
        print("  classes defined in nested configs: \(nestedTotal); not defined in the same PBO's root config: \(nestedOnlyClasses) (in \(pbosWithNestedOnly) PBOs); of those, in nested configs without CfgPatches: \(nestedNoPatchOnly)")
        for p in probes { print("  \(p) defined by: \((definers[p] ?? []).joined(separator: ", "))") }
    }
}
