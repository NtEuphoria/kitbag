// Runs on the real library: Workshop mods + the Arma 3 folder (read-only).
import Foundation

enum Real {
    static let steam = "\(NSHomeDirectory())/Library/Application Support/Steam/steamapps"
    static let workshop = URL(fileURLWithPath: steam + "/workshop/content/107410")
    static let game = URL(fileURLWithPath: steam + "/common/Arma 3")

    static func modFolders() -> [URL] {
        let ids = ((try? FileManager.default.contentsOfDirectory(atPath: workshop.path)) ?? []).filter { Int($0) != nil }.sorted()
        return ids.map { workshop.appendingPathComponent($0) }
    }

    /// `default` = the real ~/Library/Caches/Kitbag/index-v2; no argument = a scratch directory.
    static func cacheDir(_ arg: String?) -> URL {
        if arg == "default" { return ConfigIndexer.defaultCacheDirectory }
        if let arg { return URL(fileURLWithPath: arg) }
        return FileManager.default.temporaryDirectory.appendingPathComponent("kitbag-index-v2-test")
    }

    static func rssMB() -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "rss=", "-p", "\(getpid())"]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return 0 }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) / 1024
    }

    /// Polls `ps` while the closure runs.
    static func measure<T>(_ label: String, _ body: () -> T) -> T {
        var peak = rssMB()
        let start = peak
        let stop = NSLock(); var done = false
        let t = Thread {
            while true {
                stop.lock(); let d = done; stop.unlock()
                if d { break }
                peak = max(peak, rssMB())
                Thread.sleep(forTimeInterval: 0.15)
            }
        }
        t.start()
        let t0 = Date()
        let r = body()
        let secs = Date().timeIntervalSince(t0)
        stop.lock(); done = true; stop.unlock()
        Thread.sleep(forTimeInterval: 0.2)
        let end = rssMB()
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        print(String(format: "%@: %.2f s wall, RSS start %d MB, peak (ps) %d MB, end %d MB, ru_maxrss %d MB", label, secs, start, max(peak, end), end, Int(u.ru_maxrss) / 1_048_576))
        return r
    }

    static func printStats(_ s: IndexStats, _ idx: ConfigIndexer) {
        print("  PBOs \(s.pbos): cached \(s.cached) (of which text refreshed \(s.textRefreshed)), parsed \(s.parsed); configs binary \(s.binaryConfigs), text \(s.textConfigs)")
        print("  cache read \(s.cacheBytesRead / 1_048_576) MB, written \(s.cacheBytesWritten / 1_048_576) MB, write failures \(s.cacheWriteFailures), on disk \(idx.cacheSize() / 1_048_576) MB")
        print("  phases: " + s.seconds.sorted { $0.key < $1.key }.map { "\($0.key) \(String(format: "%.2f", $0.value))s" }.joined(separator: ", "))
    }

    static func cold(_ arg: String?) {
        let dir = cacheDir(arg)
        let idx = ConfigIndexer(cacheDirectory: dir)
        idx.clearCache()
        print("cache: \(dir.path)")
        var last = -1
        let index = measure("cold build") { idx.build(modFolders: modFolders(), gameFolder: game) { p in
            let pct = Int(p * 10); if pct != last { last = pct; fputs("  progress \(pct * 10)%  rss \(rssMB()) MB\n", stderr) }
        } }
        printStats(idx.lastStats, idx)
        print("  mods \(index.mods.count), vanilla classes \(index.vanilla.classCount), vanilla addons \(index.vanilla.addons.count)")
        let classes = index.mods.values.reduce(0) { $0 + $1.pbos.reduce(0) { $0 + $1.summary.classes.count } }
        print("  mod classes \(classes); RSS with the index alive: \(rssMB()) MB")
        if let hold = ProcessInfo.processInfo.environment["KITBAG_HOLD"], let secs = Double(hold) { Thread.sleep(forTimeInterval: secs) }   // time to run vmmap/footprint
        withExtendedLifetime(index) {}
    }

    static func warm(_ arg: String?) {
        let dir = cacheDir(arg)
        for round in 1...3 {
            let idx = ConfigIndexer(cacheDirectory: dir)
            let index = measure("warm build \(round)") { idx.build(modFolders: modFolders(), gameFolder: game) }
            printStats(idx.lastStats, idx)
            if round == 3 { print("  RSS with the index alive: \(rssMB()) MB") }
            withExtendedLifetime(index) {}
        }
    }

    /// Incremental behaviour on the real library, without touching any mod: damage one cache file, then change the library.
    static func incremental(_ arg: String?) {
        let dir = cacheDir(arg)
        let mods = modFolders()
        _ = ConfigIndexer(cacheDirectory: dir).build(modFolders: mods, gameFolder: game)   // make sure the cache is warm
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []).filter { $0.pathExtension == "kbi" }
        let biggest = files.max { ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) < ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }!
        try! FileManager.default.removeItem(at: biggest)
        var idx = ConfigIndexer(cacheDirectory: dir)
        _ = measure("one cache file missing") { idx.build(modFolders: mods, gameFolder: game) }
        printStats(idx.lastStats, idx)
        var fewer = mods
        fewer.remove(at: mods.firstIndex { !loadedPBOs(in: $0).isEmpty }!)   // leave out the first mod that has PBOs
        idx = ConfigIndexer(cacheDirectory: dir)
        _ = measure("one mod fewer (library changed)") { idx.build(modFolders: fewer, gameFolder: game) }
        printStats(idx.lastStats, idx)
        idx = ConfigIndexer(cacheDirectory: dir)
        _ = measure("same list again") { idx.build(modFolders: fewer, gameFolder: game) }
        printStats(idx.lastStats, idx)
        idx = ConfigIndexer(cacheDirectory: dir)
        _ = measure("back to all mods") { idx.build(modFolders: mods, gameFolder: game) }
        printStats(idx.lastStats, idx)
    }

    static func verify(_ arg: String?) {
        let dir = cacheDir(arg)
        let cached = ConfigIndexer(cacheDirectory: dir)
        let a = cached.build(modFolders: modFolders(), gameFolder: game)
        print("cache-backed build: parsed \(cached.lastStats.parsed), cached \(cached.lastStats.cached)")
        let b = ConfigIndexer(cacheDirectory: nil).build(modFolders: modFolders(), gameFolder: game)
        let d = diff(a, b)
        print(d.isEmpty ? "identical: cache-backed index equals a from-scratch index (\(a.mods.count) mods, \(a.vanilla.classCount) vanilla classes)" : "DIFFERENCES: \(d.prefix(20))")

        // Independent re-derivation: parse every rapified config straight from the PBO, bypassing the codec, the cache
        // and the selection code, and compare with what the index holds.
        func derive(_ url: URL, props: Bool) -> (summary: ConfigSummary, duplicates: Bool)? {
            guard let ar = try? PBOArchive(url: url) else { return nil }
            let bins = ar.entries.filter { $0.path == "config.bin" || $0.path.hasSuffix("\\config.bin") }.sorted { $0.path < $1.path }
            if bins.isEmpty || ar.entries.contains(where: { $0.path == "config.cpp" || $0.path.hasSuffix("\\config.cpp") }) { return nil }   // not a binary-only PBO
            var sum = ConfigSummary()
            let duplicates = Set(bins.map(\.path)).count != bins.count
            for e in bins {
                guard let data = ar.contents(of: e), let root = try? RapParser.parse(data) else { return nil }
                let s = ConfigSummary.make(from: root, includeProperties: props)
                sum.patches += s.patches; sum.classes += s.classes
            }
            return (sum, duplicates)
        }
        var compared = 0, skipped = 0, sameOrder = 0
        var duplicated: [String] = []
        var mismatches: [String] = []
        let all = a.modOrder.flatMap { a.mods[$0]!.pbos }
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: all.count) { i in
            guard let (sum, dup) = derive(URL(fileURLWithPath: all[i].path), props: true) else { lock.lock(); skipped += 1; lock.unlock(); return }
            if dup { lock.lock(); duplicated.append(all[i].path); lock.unlock(); return }   // two entries with one name: the first one wins, as in PBOArchive
            let mine = all[i].summary
            let exact = mine.patches == sum.patches && mine.classes == sum.classes
            // Same content in a different config order is fine; the order of configs within a PBO carries no meaning.
            let ok = mine.diagnostics.isEmpty && mine.patches.count == sum.patches.count && Set(mine.patches) == Set(sum.patches)
                && mine.classes.count == sum.classes.count && Set(mine.classes) == Set(sum.classes)
            lock.lock(); compared += 1; if exact { sameOrder += 1 }; if !ok { mismatches.append(all[i].path) }; lock.unlock()
        }
        print("independent re-derivation of mod PBOs with only binary configs: \(compared) compared (\(sameOrder) identical down to config order), \(mismatches.count) mismatches (\(skipped) PBOs with text configs or parse problems skipped, \(duplicated.count) with duplicate config entries set aside)")
        for m in mismatches.prefix(5) { print("  MISMATCH \(m)") }

        // Vanilla: distinct class paths and parents derived independently.
        var parents: [String: String] = [:], defined = Set<String>(), addons = Set<String>()
        for (url, _) in ConfigIndexer.vanillaPBOs(in: game) {
            guard let (sum, _) = derive(url, props: false) else { continue }
            for p in sum.patches { addons.insert(p.name) }
            for c in sum.classes {
                if c.external { if parents[c.path] == nil { parents[c.path] = "" }; continue }
                defined.insert(c.path)
                if parents[c.path]?.isEmpty ?? true { parents[c.path] = c.parent ?? "" }
            }
        }
        let vOK = parents == a.vanilla.parents && addons == a.vanilla.addons && a.vanilla.externalOnly == Set(parents.keys).subtracting(defined)
        print("independent vanilla re-derivation: \(parents.count) class paths, \(addons.count) addons, \(vOK ? "matches the index" : "DOES NOT MATCH")")
        print("vanilla diagnostics: \(a.vanilla.diagnostics.count) \(a.vanilla.diagnostics.prefix(3))")
        exit(d.isEmpty && mismatches.isEmpty && vOK ? 0 : 1)
    }

    static func modName(_ dir: URL) -> String {
        for f in ["meta.cpp", "mod.cpp"] {
            if let t = (try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)) ?? (try? String(contentsOf: dir.appendingPathComponent(f), encoding: .isoLatin1)),
               let r = t.range(of: #"name\s*=\s*"([^"]*)""#, options: .regularExpression) {
                return String(t[r]).replacingOccurrences(of: #"^name\s*=\s*""#, with: "", options: .regularExpression).dropLast().description
            }
        }
        return dir.lastPathComponent
    }

    static func report(_ arg: String?) {
        let idx = ConfigIndexer(cacheDirectory: cacheDir(arg))
        let index = idx.build(modFolders: modFolders(), gameFolder: game)
        printStats(idx.lastStats, idx)
        let v = index.vanilla
        print("\nVANILLA: \(v.pbos.count) PBOs, \(v.classCount) classes (\(v.externalOnly.count) forward-declared only), \(v.addons.count) addons")
        var vanillaParents = 0
        for (_, p) in v.parents where !p.isEmpty { vanillaParents += 1 }
        print("  classes with a base class: \(vanillaParents); sample b_soldier_f parent: \(v.parent(of: "cfgvehicles/b_soldier_f") ?? "nil"), car parent: \(v.parent(of: "cfgvehicles/car") ?? "nil")")
        let dlc = Dictionary(grouping: v.addonSource.values) { $0.contains("/") ? String($0.split(separator: "/")[0]) : "(Addons)" }
        print("  addons by folder: " + dlc.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.count)" }.joined(separator: ", "))

        let mods = index.modOrder.compactMap { index.mods[$0] }
        let pbos = mods.flatMap(\.pbos)
        let patches = pbos.reduce(0) { $0 + $1.summary.patches.count }
        let classes = pbos.reduce(0) { $0 + $1.summary.classes.count }
        let externals = pbos.reduce(0) { $0 + $1.summary.classes.filter(\.external).count }
        print("\nMODS: \(mods.count) folders, \(mods.filter { !$0.hasAddonsFolder }.count) without an addons folder, \(pbos.count) loaded PBOs")
        print("  CfgPatches entries \(patches) (\(Set(pbos.flatMap { $0.summary.patches.map(\.name) }).count) distinct), classes \(classes) (\(externals) external)")
        print("  PBOs without any config: \(pbos.filter { $0.configFiles.isEmpty }.count); PBOs with configs but no CfgPatches: \(pbos.filter { !$0.configFiles.isEmpty && $0.summary.patches.isEmpty }.count)")
        print("  config files indexed: binary \(idx.lastStats.binaryConfigs), text \(idx.lastStats.textConfigs); nested (not at the PBO root): \(pbos.flatMap(\.configFiles).filter { $0.contains("\\") }.count)")
        census(index)
        print("  PBOs with configs but no CfgPatches:")
        for m in mods { for p in m.pbos where !p.configFiles.isEmpty && p.summary.patches.isEmpty {
            print("    \(modName(URL(fileURLWithPath: m.path))) / \(p.name): \(p.configFiles.joined(separator: ", ")) -> \(p.summary.classes.count) classes, top-level: \(Set(p.summary.classes.filter { !$0.path.contains("/") }.map(\.path)).sorted().joined(separator: ","))")
        } }
        let hasInc = pbos.filter(\.usesHasInclude)
        let probes = Set(hasInc.flatMap { $0.hasIncludeProbes.keys })
        print("  PBOs using __has_include: \(hasInc.count) in \(Set(mods.filter { $0.pbos.contains(where: \.usesHasInclude) }.map(\.path)).count) mods, \(probes.count) distinct paths")
        for m in mods { for p in m.pbos where p.usesHasInclude {
            print("    \(modName(URL(fileURLWithPath: m.path))) / \(p.name): " + p.hasIncludeProbes.sorted { $0.key < $1.key }.prefix(5).map { "\($0.key)=\($0.value ? "yes" : "no")" }.joined(separator: " "))
        } }
        let win = mods.filter { !$0.windowsOnlyExtensions.isEmpty }, mac = mods.filter { !$0.macExtensions.isEmpty }
        print("  mods with root .dll and no Mac library: \(win.count); mods shipping .dylib/.so: \(mac.count)")

        // Diagnostics, grouped by kind.
        var byKind: [String: [(String, String)]] = [:]
        for m in mods { for p in m.pbos { for d in p.summary.diagnostics {
            byKind[String(d.prefix { $0 != ":" }), default: []].append((modName(URL(fileURLWithPath: m.path)) + " / " + p.name, d))
        } } }
        print("\nDIAGNOSTICS: \(byKind.values.reduce(0) { $0 + $1.count }) in \(pbos.filter { !$0.summary.diagnostics.isEmpty }.count) PBOs")
        for (k, list) in byKind.sorted(by: { $0.key < $1.key }) {
            print("  \(k): \(list.count)")
            for (who, d) in list.prefix(12) { print("    [\(who)] \(d.prefix(260))") }
        }
        let vanillaDiags = v.pbos.count  // vanilla summaries are reduced; their diagnostics surface via the cold-run failures below
        _ = vanillaDiags
        let failures = (byKind["parse failure"]?.count ?? 0) + (byKind["unreadable pbo"]?.count ?? 0) + (byKind["unreadable config"]?.count ?? 0)
        print("\nPARSE/PREPROCESS FAILURES (mods): \(failures)")
        let unresolved = byKind["unresolved include"]?.count ?? 0
        print("unresolved includes: \(unresolved)")
    }

    /// Where the memory of a mod index goes: how many strings spill to the heap and how much dictionary sharing is possible.
    static func census(_ index: GameIndex) {
        var classes = 0, withProps = 0, props = 0, heapPaths = 0, pathBytes = 0, heapParents = 0, deletes = 0
        var heapKeys = 0, heapValues = 0
        var distinctDicts = Set<[String: String]>(), distinctValues = Set<String>(), distinctKeys = Set<String>()
        var propsInDistinct = 0
        for m in index.mods.values { for p in m.pbos { for c in p.summary.classes {
            classes += 1
            if c.path.utf8.count > 15 { heapPaths += 1; pathBytes += c.path.utf8.count }
            if let par = c.parent, par.utf8.count > 15 { heapParents += 1 }
            deletes += c.deletes.count
            guard !c.props.isEmpty else { continue }
            withProps += 1; props += c.props.count
            if distinctDicts.insert(c.props).inserted { propsInDistinct += c.props.count }
            for (k, v) in c.props {
                if k.utf8.count > 15 { heapKeys += 1 }
                if v.utf8.count > 15 { heapValues += 1 }
                distinctKeys.insert(k); distinctValues.insert(v)
            }
        } } }
        print("census: \(classes) classes, \(withProps) with properties (\(props) properties, avg \(String(format: "%.1f", Double(props) / Double(max(withProps, 1)))))")
        print("  paths over 15 bytes (heap): \(heapPaths), avg \(pathBytes / max(heapPaths, 1)) bytes; parents over 15: \(heapParents); keys over 15: \(heapKeys), values over 15: \(heapValues)")
        print("  distinct property dictionaries: \(distinctDicts.count) (\(propsInDistinct) entries) of \(withProps); distinct keys \(distinctKeys.count), distinct values \(distinctValues.count)")
    }

    /// Real-library playset test: switch off every mod that provides a `__has_include` target and see what changes.
    static func conditional(_ arg: String?) {
        let idx = ConfigIndexer(cacheDirectory: cacheDir(arg))
        var index = idx.build(modFolders: modFolders(), gameFolder: game)
        let base = index
        let all = Set(index.modOrder)
        let users = index.modOrder.filter { m in index.mods[m]!.pbos.contains(where: \.usesHasInclude) }
        print("mods with __has_include PBOs: \(users.count)")
        var t = Date()
        var redone = idx.reindexConditional(index: &index, enabledModPaths: all)
        print(String(format: "all mods enabled: %d PBOs redone, %.2f s", redone.count, Date().timeIntervalSinceNow * -1 - 0 * t.timeIntervalSinceNow))
        // Every probed path -> the mod that provides it.
        let providers: [String: String] = {
            var m: [String: String] = [:]
            for p in Set(base.mods.values.flatMap { $0.pbos.flatMap { $0.hasIncludeProbes.keys } }) {
                for folder in base.modOrder {
                    guard let mod = base.mods[folder] else { continue }
                    for pbo in mod.pbos {
                        let root = pbo.prefix.isEmpty ? (pbo.name as NSString).deletingPathExtension.lowercased() : pbo.prefix
                        if p.hasPrefix(root + "\\") { m[p] = folder; break }
                    }
                    if m[p] != nil { break }
                }
            }
            return m
        }()
        let providerMods = Set(providers.values)
        print("probed paths: \(providers.count) provided by \(providerMods.count) installed mods")
        t = Date()
        redone = idx.reindexConditional(index: &index, enabledModPaths: all.subtracting(providerMods))
        print(String(format: "without the %d providing mods: %d PBOs redone in %.2f s", providerMods.count, redone.count, Date().timeIntervalSince(t)))
        for p in redone.prefix(12) {
            let name = (p as NSString).lastPathComponent
            let old = base.mods.values.flatMap(\.pbos).first { $0.path == p }!, new = index.mods.values.flatMap(\.pbos).first { $0.path == p }!
            let oldReq = Set(old.summary.patches.flatMap(\.requiredAddons)), newReq = Set(new.summary.patches.flatMap(\.requiredAddons))
            print("  \(name): requiredAddons \(oldReq.count) -> \(newReq.count); dropped \(oldReq.subtracting(newReq).sorted().prefix(4)); diagnostics \(new.summary.diagnostics.prefix(2))")
        }
        redone = idx.reindexConditional(index: &index, enabledModPaths: all)
        let d = diff(base, index)
        print("back to all mods: \(redone.count) redone; differences from the baseline: \(d)")
    }
}
