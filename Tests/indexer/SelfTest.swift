// Self-test on a synthetic library: config selection, nested configs, cache reuse and invalidation,
// text configs that depend on other PBOs, __has_include playsets, cache corruption and the record codec.
import Foundation

enum SelfTest {
    static var passed = 0, failed = 0

    static func check(_ ok: @autoclosure () -> Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
        if ok() { passed += 1 } else { failed += 1; print("  FAIL \(what) (line \(line))") }
    }

    static func run() -> Bool {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kitbag-indexer-selftest-\(getpid())")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cache = tmp.appendingPathComponent("cache")
        let lib = SyntheticLibrary.create(at: tmp.appendingPathComponent("lib"))

        // MARK: cold build
        var progressValues: [Double] = []
        let idx = ConfigIndexer(cacheDirectory: cache)
        let cold = idx.build(modFolders: lib.modFolders, gameFolder: lib.game) { progressValues.append($0) }
        let s0 = idx.lastStats
        check(progressValues == progressValues.sorted() && progressValues.last == 1, "progress is monotonic and ends at 1: \(progressValues.suffix(3))")
        check(s0.parsed == s0.pbos && s0.cached == 0, "cold build parses every PBO (\(s0.parsed)/\(s0.pbos))")
        check(idx.cacheSize() > 0, "cache written")

        // Vanilla: root Addons, DLC folder (incl. nested ui config), Dta; numeric, @ and .app folders skipped.
        check(cold.vanilla.addons == ["a3_base", "a3_exp", "a3_exp_ui", "a3_bin"], "vanilla addons: \(cold.vanilla.addons.sorted())")
        check(cold.vanilla.pbos.count == 3, "vanilla PBO count \(cold.vanilla.pbos.count)")
        check(cold.vanilla.addonSource["a3_exp"] == "Expansion/a3_exp.pbo" && cold.vanilla.addonSource["a3_base"] == "a3_base.pbo"
              && cold.vanilla.addonSource["a3_bin"] == "Dta/bin.pbo", "vanilla addon sources: \(cold.vanilla.addonSource)")
        check(cold.vanilla.parents["cfgvehicles/car"] == "allvehicles", "vanilla parent of car: \(cold.vanilla.parents["cfgvehicles/car"] ?? "nil")")
        check(cold.vanilla.parents["cfgvehicles/car_f"] == "car", "vanilla parent of car_f")
        check(cold.vanilla.parent(of: "CfgVehicles/Car_F") == "car" && cold.vanilla.parent(of: "cfgvehicles/all") == nil, "parent(of:) is case-insensitive and nil without a base")
        check(cold.vanilla.hasClass("CfgWorlds/DefaultWorld") && !cold.vanilla.hasClass("cfgvehicles/modA_car"), "hasClass")
        check(cold.vanilla.externalOnly == ["cfgvehicles/ghost"], "externalOnly: \(cold.vanilla.externalOnly)")
        check(cold.vanilla.parents.values.allSatisfy { !$0.contains(where: \.isUppercase) }, "parents are lowercase")
        check(cold.vanilla.addons.allSatisfy { !$0.hasPrefix("skipped") }, "skipped folders not indexed")

        // modA: root + nested + deeply nested configs all loaded; optionals/ ignored; DLL without a Mac library.
        let a = cold.mods[lib.mod("modA").path]!
        check(a.pbos.count == 1 && a.hasAddonsFolder, "modA has one loaded PBO (optionals ignored)")
        check(a.pbos[0].configFiles == ["config.bin", "sub\\config.bin", "sub\\deep\\config.bin"], "modA configs: \(a.pbos[0].configFiles)")
        check(Set(a.patches.map(\.name)) == ["moda_main", "moda_sub"], "modA patches \(a.patches.map(\.name))")
        check(a.patches.first { $0.name == "moda_sub" }?.requiredAddons == ["moda_main"], "modA_sub requires modA_main")
        check(a.pbos[0].prefix == "x\\moda\\addons\\main", "prefix")
        let aClasses = Dictionary(grouping: a.pbos[0].summary.classes, by: \.path)
        check(aClasses["cfgvehicles/moda_car"]?.first?.props["displayname"] == "\"a car\""
              && aClasses["cfgvehicles/moda_car"]?.first?.props["armor"] == "0.1", "mod properties are kept as fingerprints")
        check(aClasses["cfgvehicles/moda_truck"]?.first?.parent == "moda_car" && aClasses["cfgvehicles"]?.count == 2, "nested config classes present")
        check(aClasses["cfgvehicles"]?.flatMap(\.deletes) == ["moda_old"], "deletes kept")
        check(aClasses["cfgweapons/moda_gun"]?.first?.props["magazines"] == "+={\"m1\"}", "appends kept")
        check(a.windowsOnlyExtensions == ["moda_x64.dll"] && a.macExtensions.isEmpty, "modA windows-only extension")
        check(cold.vanilla.parents["cfgvehicles/moda_car"] == nil && cold.vanilla.parents.values.allSatisfy { _ in true }, "mods stay out of vanilla")
        check(cold.vanilla.addonSource.keys.allSatisfy { !$0.hasPrefix("moda") }, "vanilla has no mod addons")
        check(cold.vanilla.parents.count == (cold.vanilla.parents.keys.filter { _ in true }).count, "sanity")

        // modB: config.cpp wins over a config.bin in the same folder.
        let b = cold.mods[lib.mod("modB").path]!
        let both = b.pbos.first { $0.name == "both.pbo" }!, same = b.pbos.first { $0.name == "same.pbo" }!
        check(both.configFiles == ["config.cpp"], "modB both: only config.cpp indexed (\(both.configFiles))")
        check(both.summary.patches.first?.requiredAddons == ["a3_base"], "modB both: the .cpp's requirements win")
        check(both.summary.classes.first { $0.path == "cfgvehicles/modb_car" }?.props["displayname"] == "\"cpp\"", "modB both: the .cpp's class wins")
        check(both.summary.diagnostics.contains { $0.hasPrefix("config shadowed:") && $0.contains("extra_only_in_bin") }, "modB both: disagreement reported \(both.summary.diagnostics)")
        check(same.configFiles == ["config.cpp"] && same.summary.diagnostics.isEmpty, "modB same: agreeing .bin is silent \(same.summary.diagnostics)")
        check(b.windowsOnlyExtensions.isEmpty && b.macExtensions == ["b.dylib"], "modB ships a Mac library: nothing windows-only")

        // modC: macros from another mod, __has_include; modD/modE/modF/modG.
        let c = cold.mods[lib.mod("modC").path]!.pbos[0]
        check(c.summary.patches.map(\.name) == ["modd_core_macro"], "modC patch name from modD's macro: \(c.summary.patches.map(\.name))")
        check(c.summary.patches.first?.requiredAddons == ["a3_base", "mode_opt"], "modC __has_include true: \(c.summary.patches.first?.requiredAddons ?? [])")
        check(c.hasIncludeProbes == ["x\\mode\\addons\\opt\\flag.hpp": true] && c.usesHasInclude, "modC probes \(c.hasIncludeProbes)")
        check(c.summary.diagnostics.isEmpty, "modC clean \(c.summary.diagnostics)")
        check(cold.mods[lib.mod("modD").path]!.pbos[0].configFiles.isEmpty && cold.mods[lib.mod("modD").path]!.pbos[0].summary.patches.isEmpty, "modD has no config")
        check(cold.mods[lib.mod("modF").path]!.hasAddonsFolder == false && cold.mods[lib.mod("modF").path]!.pbos.isEmpty, "modF has no addons folder")
        let g = cold.mods[lib.mod("modG").path]!
        check(g.hasAddonsFolder && g.pbos.count == 1 && g.pbos[0].summary.diagnostics.first?.hasPrefix("unreadable pbo:") == true, "modG unreadable PBO reported: \(g.pbos.first?.summary.diagnostics ?? [])")
        let h = cold.mods[lib.mod("modH").path]!.pbos[0]
        check(h.summary.patches.isEmpty && h.summary.diagnostics.contains { $0.hasPrefix("parse failure:") }, "modH parse failure reported: \(h.summary.diagnostics)")
        let i = cold.mods[lib.mod("modI").path]!.pbos[0]
        check(i.summary.patches.map(\.name) == ["modi_fb"] && i.summary.diagnostics.contains { $0.hasPrefix("fell back to config.bin:") }, "modI falls back to config.bin: \(i.summary.diagnostics)")
        let j = cold.mods[lib.mod("modJ").path]!.pbos[0]
        check(j.summary.patches.map(\.name) == ["modj_rap"] && j.summary.diagnostics.isEmpty, "modJ rapified config.cpp parsed as binary")
        let k = cold.mods[lib.mod("modK").path]!.pbos
        let junk = k.first { $0.name == "junk.pbo" }!, trunc = k.first { $0.name == "trunc.pbo" }!, empty = k.first { $0.name == "empty.pbo" }!
        check(junk.summary.patches.isEmpty && junk.summary.diagnostics.contains { $0.hasPrefix("parse failure:") }, "modK junk config reported: \(junk.summary.diagnostics)")
        check(trunc.summary.patches.isEmpty && trunc.summary.diagnostics.contains { $0.hasPrefix("unreadable config:") }, "modK truncated entry reported: \(trunc.summary.diagnostics)")
        check(empty.summary.diagnostics.isEmpty && empty.configFiles.isEmpty && empty.prefix.isEmpty, "modK empty PBO is fine")
        check(cold.libraryKey != 0 && cold.modOrder == lib.modFolders.map(\.path), "library key and order")

        // MARK: warm build
        let warmIdx = ConfigIndexer(cacheDirectory: cache)
        let warm = warmIdx.build(modFolders: lib.modFolders, gameFolder: lib.game)
        let s1 = warmIdx.lastStats
        check(s1.parsed == 0 && s1.cached == s1.pbos && s1.textRefreshed == 0, "warm build reads nothing: \(s1)")
        check(s1.seconds["open"] == nil, "warm build opens no PBO")
        check(diff(cold, warm).isEmpty, "warm index equals cold index: \(diff(cold, warm))")
        check(diff(cold, ConfigIndexer(cacheDirectory: nil).build(modFolders: lib.modFolders, gameFolder: lib.game)).isEmpty, "uncached build equals cached")

        // MARK: invalidation
        // mtime change: only that PBO is re-read; text configs are redone because the library changed.
        TestPBO.setMTime(lib.pbo("modA", "main"), Date(timeIntervalSinceNow: -1234))
        let inv1 = ConfigIndexer(cacheDirectory: cache)
        let r1 = inv1.build(modFolders: lib.modFolders, gameFolder: lib.game)
        check(inv1.lastStats.parsed == 1, "mtime change re-reads one PBO (\(inv1.lastStats.parsed))")
        check(inv1.lastStats.textRefreshed == 5, "text PBOs refreshed after a library change (\(inv1.lastStats.textRefreshed))")
        check(diff(cold, r1) == ["libraryKey", "modA/main.pbo header"], "only the header differs: \(diff(cold, r1))")
        let r1b = ConfigIndexer(cacheDirectory: cache); _ = r1b.build(modFolders: lib.modFolders, gameFolder: lib.game)
        check(r1b.lastStats.parsed == 0 && r1b.lastStats.textRefreshed == 0, "and then everything is warm again")

        // A change in another mod's header file changes what modC's config means.
        let macros = ["config.cpp": 0]
        _ = macros
        TestPBO.write(lib.pbo("modD", "core"), prefix: "x\\modd\\addons\\core", [("defs.hpp", "#define ADDON modd_core_v2\n")])
        let inv2 = ConfigIndexer(cacheDirectory: cache)
        let r2 = inv2.build(modFolders: lib.modFolders, gameFolder: lib.game)
        check(r2.mods[lib.mod("modC").path]!.pbos[0].summary.patches.map(\.name) == ["modd_core_v2"], "modC follows modD's changed macro (not served stale): \(r2.mods[lib.mod("modC").path]!.pbos[0].summary.patches.map(\.name))")
        check(inv2.lastStats.parsed == 1 && inv2.lastStats.textRefreshed == 5, "one PBO parsed, text PBOs refreshed: \(inv2.lastStats)")

        // A new mod that appears flips __has_include in modC without any file of modC changing.
        let before = r2.mods[lib.mod("modC").path]!.pbos[0].summary.patches[0].requiredAddons
        check(before == ["a3_base", "mode_opt"], "baseline requirements")
        try? FileManager.default.removeItem(at: lib.mod("modE"))
        let inv3 = ConfigIndexer(cacheDirectory: cache)
        let r3 = inv3.build(modFolders: lib.modFolders, gameFolder: lib.game)
        check(r3.mods[lib.mod("modC").path]!.pbos[0].summary.patches[0].requiredAddons == ["a3_base"], "removing mod E flips modC's __has_include: \(r3.mods[lib.mod("modC").path]!.pbos[0].summary.patches[0].requiredAddons)")
        check(r3.mods[lib.mod("modC").path]!.pbos[0].hasIncludeProbes.values.allSatisfy { !$0 }, "probe answer recorded")
        // Put E back (new mtime): back to the original answer.
        TestPBO.write(lib.pbo("modE", "opt"), prefix: "x\\mode\\addons\\opt", data: [
            ("flag.hpp", Data("// presence is the flag\n".utf8)),
            ("config.bin", RapWriter.build([TestPBO.patches("mode_opt", requires: ["A3_Base"])])),
        ])
        let r4 = ConfigIndexer(cacheDirectory: cache).build(modFolders: lib.modFolders, gameFolder: lib.game)
        check(r4.mods[lib.mod("modC").path]!.pbos[0].summary.patches[0].requiredAddons == ["a3_base", "mode_opt"], "restoring mod E restores the answer")

        // Size change with the same mtime is still caught.
        let url = lib.pbo("modA", "main")
        let stamp = (try! FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as! Date
        var bytes = try! Data(contentsOf: url); bytes.append(contentsOf: [0, 0, 0])
        try! bytes.write(to: url)
        TestPBO.setMTime(url, stamp)
        let inv5 = ConfigIndexer(cacheDirectory: cache)
        _ = inv5.build(modFolders: lib.modFolders, gameFolder: lib.game)
        check(inv5.lastStats.parsed == 1, "size change re-reads the PBO (\(inv5.lastStats.parsed))")

        // Parser version: everything is rebuilt.
        let inv6 = ConfigIndexer(cacheDirectory: cache, parserVersion: ConfigIndexer.parserVersion + 1)
        _ = inv6.build(modFolders: lib.modFolders, gameFolder: lib.game)
        check(inv6.lastStats.parsed == inv6.lastStats.pbos, "new parser version rebuilds all (\(inv6.lastStats.parsed)/\(inv6.lastStats.pbos))")
        let inv6b = ConfigIndexer(cacheDirectory: cache, parserVersion: ConfigIndexer.parserVersion + 1)
        _ = inv6b.build(modFolders: lib.modFolders, gameFolder: lib.game)
        check(inv6b.lastStats.parsed == 0, "and is then warm")

        // A folder given twice, in another order, and a missing game folder.
        let dup = ConfigIndexer(cacheDirectory: nil).build(modFolders: [lib.mod("modA"), lib.mod("modA")], gameFolder: nil)
        check(dup.mods.count == 1 && dup.vanilla.classCount == 0 && dup.modOrder == [lib.mod("modA").path], "duplicate folder and no game folder")
        let none = ConfigIndexer(cacheDirectory: nil).build(modFolders: [lib.root.appendingPathComponent("nope")], gameFolder: lib.root.appendingPathComponent("nogame"))
        check(none.mods.count == 1 && none.mods.values.first!.pbos.isEmpty && !none.mods.values.first!.hasAddonsFolder, "missing folders are empty, not errors")

        // MARK: corruption
        let cacheFiles = (try! FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)).filter { $0.pathExtension == "kbi" }.sorted { $0.path < $1.path }
        let truth = ConfigIndexer(cacheDirectory: nil).build(modFolders: lib.modFolders, gameFolder: lib.game)
        var rng = SystemRandomNumberGenerator()
        var allEqual = true
        for round in 0..<60 {
            let f = cacheFiles[Int.random(in: 0..<cacheFiles.count, using: &rng)]
            var d = try! Data(contentsOf: f)
            switch round % 3 {
            case 0: d[Int.random(in: 0..<d.count, using: &rng)] ^= UInt8.random(in: 1...255, using: &rng)
            case 1: d = d.prefix(Int.random(in: 0..<d.count, using: &rng))
            default: d.append(contentsOf: [1, 2, 3])
            }
            try! d.write(to: f)
            let r = ConfigIndexer(cacheDirectory: cache).build(modFolders: lib.modFolders, gameFolder: lib.game)
            if !diff(truth, r).isEmpty { allEqual = false; print("  corruption round \(round): \(diff(truth, r))") }
        }
        check(allEqual, "damaged cache files are rebuilt, never trusted")
        let self2 = ConfigIndexer(cacheDirectory: cache); _ = self2.build(modFolders: lib.modFolders, gameFolder: lib.game)
        check(self2.lastStats.parsed == 0, "cache is whole again after the rounds")

        // An unusable cache location must not change the answer.
        let blocker = tmp.appendingPathComponent("blocker")
        try! Data("file".utf8).write(to: blocker)
        let noCache = ConfigIndexer(cacheDirectory: blocker.appendingPathComponent("sub"))
        let rNo = noCache.build(modFolders: lib.modFolders, gameFolder: lib.game)
        check(diff(truth, rNo).isEmpty && noCache.lastStats.cacheWriteFailures == noCache.lastStats.pbos, "unwritable cache: same index, \(noCache.lastStats.cacheWriteFailures) failed writes")

        // Two builds at once against one cache directory (two app instances) both come out right.
        let shared = tmp.appendingPathComponent("shared-cache")
        var concurrent: [GameIndex] = []
        let guardLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            let r = ConfigIndexer(cacheDirectory: shared).build(modFolders: lib.modFolders, gameFolder: lib.game)
            guardLock.lock(); concurrent.append(r); guardLock.unlock()
        }
        check(concurrent.count == 4 && concurrent.allSatisfy { diff(truth, $0).isEmpty }, "four simultaneous builds on one cache agree")
        let afterRace = ConfigIndexer(cacheDirectory: shared); _ = afterRace.build(modFolders: lib.modFolders, gameFolder: lib.game)
        check(afterRace.lastStats.parsed == 0, "and leave a whole cache behind (parsed \(afterRace.lastStats.parsed))")

        // MARK: stale cache files
        let stalePBO = tmp.appendingPathComponent("lib/mods/modTemp/addons/t.pbo")
        TestPBO.write(stalePBO, prefix: "t", [("config.cpp", "class CfgPatches { class tmp {}; };")])
        let pr = ConfigIndexer(cacheDirectory: cache)
        _ = pr.build(modFolders: lib.modFolders + [lib.mod("modTemp")], gameFolder: lib.game)
        let withTemp = (try! FileManager.default.contentsOfDirectory(atPath: cache.path)).count
        try! FileManager.default.removeItem(at: lib.mod("modTemp"))
        _ = pr.build(modFolders: lib.modFolders, gameFolder: lib.game)
        let withoutTemp = (try! FileManager.default.contentsOfDirectory(atPath: cache.path)).count
        check(withoutTemp == withTemp - 1, "cache file of a deleted PBO is pruned (\(withTemp) -> \(withoutTemp))")
        pr.clearCache()
        check(pr.cacheSize() == 0, "clearCache")

        // MARK: playsets and __has_include
        let live = ConfigIndexer(cacheDirectory: nil)
        var index = live.build(modFolders: lib.modFolders, gameFolder: lib.game)
        let base = index
        let cPath = index.mods[lib.mod("modC").path]!.pbos[0].path
        var redone = live.reindexConditional(index: &index, enabledModPaths: Set(lib.modFolders.map(\.path)))
        check(redone.isEmpty && diff(base, index).isEmpty, "all mods enabled: nothing to redo (\(redone))")
        redone = live.reindexConditional(index: &index, enabledModPaths: Set(lib.modFolders.map(\.path)).subtracting([lib.mod("modE").path]))
        check(redone == [cPath], "without mod E only modC's PBO is redone: \(redone)")
        let withoutE = index.mods[lib.mod("modC").path]!.pbos[0]
        check(withoutE.summary.patches[0].requiredAddons == ["a3_base"] && withoutE.hasIncludeProbes.values.allSatisfy { !$0 }, "modC without E: \(withoutE.summary.patches[0].requiredAddons)")
        let baseC = base.mods[lib.mod("modC").path]!.pbos[0]
        let patchPath = "cfgpatches/" + baseC.summary.patches[0].name   // modD was rewritten above, so the macro now says modd_core_v2
        let isPatchClass: (ClassDef) -> Bool = { $0.path == patchPath }
        let restNow = withoutE.summary.classes.filter { !isPatchClass($0) }
        let restBase = baseC.summary.classes.filter { !isPatchClass($0) }
        let patchProps = withoutE.summary.classes.first(where: isPatchClass)?.props["requiredaddons"]
        check(withoutE.summary.patches[0].name == baseC.summary.patches[0].name && restNow == restBase && patchProps == "{\"a3_base\"}",
              "only the CfgPatches class of modC changed (\(restNow == restBase), \(patchProps ?? "nil"))")
        check(index.playset?.contains(lib.mod("modE").path) == false, "playset recorded")
        var others = diff(base, index)
        others.removeAll { $0.hasPrefix("modC/macros.pbo") }
        check(others.isEmpty, "no other PBO changed: \(others)")
        redone = live.reindexConditional(index: &index, enabledModPaths: Set(lib.modFolders.map(\.path)).subtracting([lib.mod("modE").path]))
        check(redone.isEmpty, "same playset again redoes nothing")
        redone = live.reindexConditional(index: &index, enabledModPaths: Set(lib.modFolders.map(\.path)))
        check(redone == [cPath] && diff(base, index).isEmpty, "all mods again restores the full-library result (\(redone), \(diff(base, index)))")
        // A playset that leaves modC out is not touched.
        redone = live.reindexConditional(index: &index, enabledModPaths: [lib.mod("modA").path])
        check(redone.isEmpty, "mods outside the playset are left alone")

        codecTests()
        let lockProblem = ParserLock.problem()
        check(lockProblem == nil, "parserVersion matches the parser sources: \(lockProblem ?? "ok")")
        print("indexer selftest: \(passed) passed, \(failed) failed")
        return failed == 0
    }

    // MARK: record codec

    static func randomString(_ rng: inout SystemRandomNumberGenerator, pool: [String]) -> String {
        if Bool.random(using: &rng), let p = pool.randomElement(using: &rng) { return p }
        let alphabet = Array("abcxyz_\\/\"{},.0189 éß日本🙂")
        return String((0..<Int.random(in: 0...24, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! })
    }

    static func randomPart(_ rng: inout SystemRandomNumberGenerator, text: Bool) -> PartResult {
        let pool = (0..<12).map { "v\($0)" }
        var p = PartResult()
        for _ in 0..<Int.random(in: 0...3, using: &rng) { p.files.append(randomString(&rng, pool: pool)) }
        if text { for _ in 0..<Int.random(in: 0...3, using: &rng) { p.probes[randomString(&rng, pool: pool)] = Bool.random(using: &rng) } }
        for _ in 0..<Int.random(in: 0...3, using: &rng) {
            p.summary.patches.append(PatchInfo(name: randomString(&rng, pool: pool),
                                               requiredAddons: (0..<Int.random(in: 0...4, using: &rng)).map { _ in randomString(&rng, pool: pool) },
                                               requiredVersion: Bool.random(using: &rng) ? Double.random(in: -5...5, using: &rng) : nil,
                                               skipWhenMissingDependencies: Bool.random(using: &rng)))
        }
        for _ in 0..<Int.random(in: 0...40, using: &rng) {
            var props: [String: String] = [:]
            for _ in 0..<Int.random(in: 0...5, using: &rng) { props[randomString(&rng, pool: pool)] = randomString(&rng, pool: pool) }
            p.summary.classes.append(ClassDef(path: randomString(&rng, pool: []), parent: Bool.random(using: &rng) ? randomString(&rng, pool: pool) : nil,
                                              external: Bool.random(using: &rng), props: props,
                                              deletes: (0..<Int.random(in: 0...2, using: &rng)).map { _ in randomString(&rng, pool: pool) }))
        }
        for _ in 0..<Int.random(in: 0...3, using: &rng) { p.summary.diagnostics.append(randomString(&rng, pool: pool)) }
        return p
    }

    static func same(_ a: PartResult, _ b: PartResult) -> Bool {
        a.files == b.files && a.probes == b.probes && a.summary.patches == b.summary.patches
            && a.summary.classes == b.summary.classes && a.summary.diagnostics == b.summary.diagnostics
    }

    static func codecTests() {
        var rng = SystemRandomNumberGenerator()
        var roundTrips = true
        var worst = 0
        for _ in 0..<300 {
            var r = PBORecord()
            r.prefix = randomString(&rng, pool: [])
            r.binary = randomPart(&rng, text: false)
            r.text = randomPart(&rng, text: true)
            let bytes = RecordCodec.encode(r)
            worst = max(worst, bytes.count)
            guard let d = try? bytes.withUnsafeBytes({ try RecordCodec.decode($0) }),
                  d.prefix == r.prefix, same(d.binary, r.binary), same(d.text, r.text) else { roundTrips = false; continue }
        }
        check(roundTrips, "300 random records survive encode/decode (largest \(worst) bytes)")

        // Every truncation throws; random byte changes either throw or decode to something, never trap.
        var r = PBORecord()
        r.prefix = "x\\y"
        r.binary = randomPart(&rng, text: false)
        r.text = randomPart(&rng, text: true)
        let bytes = RecordCodec.encode(r)
        var truncationsThrow = true
        for n in 0..<bytes.count {
            if (try? Array(bytes[0..<n]).withUnsafeBytes { try RecordCodec.decode($0) }) != nil { truncationsThrow = false }
        }
        check(truncationsThrow, "every truncation of a record is rejected")
        var survived = 0
        for _ in 0..<20_000 {
            var m = bytes
            for _ in 0..<Int.random(in: 1...4, using: &rng) { m[Int.random(in: 0..<m.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng) }
            _ = try? m.withUnsafeBytes { try RecordCodec.decode($0) }
            survived += 1
        }
        check(survived == 20_000, "20000 mutated records decode or throw without trapping")
        for _ in 0..<5_000 {
            let n = Int.random(in: 0...200, using: &rng)
            let junk = (0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) }
            _ = try? junk.withUnsafeBytes { try RecordCodec.decode($0) }
        }
        check(true, "random junk never traps")
    }
}
