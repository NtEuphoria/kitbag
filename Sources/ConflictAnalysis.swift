// Conflict analysis: what goes wrong when the enabled mods' configs are merged by Arma 3.
// Works on the config index (no PBO is opened): missing dependencies, undefined base classes,
// base-class changes, property override fights, duplicate addons and PBO prefix collisions.
import Foundation

// MARK: - Findings

/// One problem found in a playset. Every finding carries the concrete config facts it rests on.
struct ConflictFinding: Codable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case missingDependency, undefinedBaseClass, baseClassChange, propertyConflict, duplicateAddon, prefixCollision
    }
    enum Severity: Int, Codable, Comparable {
        case info, warning, error
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    let kind: Kind
    let severity: Severity
    /// Mod folders the finding is about; the mod to blame (or the first of a pair) comes first.
    let modPaths: [String]
    let title: String
    let detail: String
    /// Config facts behind the finding, most telling first. Capped; the last line says how many were left out.
    let evidence: [String]
    /// 0...1: how sure the analysis is that this is a real in-game problem.
    let confidence: Double
    /// Installed but disabled mods that would fix it.
    let suggestedEnable: [String]
    /// Enabled mods that are redundant or to blame.
    let suggestedDisable: [String]

    var id: String { kind.rawValue + "|" + modPaths.joined(separator: "|") + "|" + title }
}

// MARK: - Context

/// Everything about a library that does not depend on which mods are enabled, precomputed once, so that
/// `analyze` only has to filter small tables by the enabled set.
///
/// Arma 3 semantics this relies on (BI Community Wiki: Class Inheritance, CfgPatches, Config Reference):
/// - Every addon (CfgPatches class) loads after the addons in its `requiredAddons`; an addon whose required
///   addon is absent is refused ("Addon X requires addon Y") unless `skipWhenMissingDependencies = 1`, which
///   silently drops it. Addons with no dependency path between them load in an order the config does not define.
/// - Configs are merged class by class. A later definition of an existing class overrides its properties; naming
///   a different base class changes the base ("Updating base class"); array `+=` appends.
/// - A base class is looked up by name in the enclosing scope, in that scope's own base classes, and outward.
///   `class A: A` inside a derived class therefore means the same-named member of its parent.
final class ConflictContext {
    private let t: Tables

    /// Builds the tables from an index (all installed mods). `names` maps mod folder → display name; folders
    /// are shown by their last path component when missing. Takes a few seconds for a large library.
    init(index: GameIndex, names: [String: String] = [:]) {
        t = Tables(index: index, names: names)
    }

    /// Analyzes the playset made of `enabled` (mod folder paths; unknown paths are ignored) plus the base game.
    /// Findings are sorted most severe first.
    func analyze(enabled: [String]) -> [ConflictFinding] {
        var on = [Bool](repeating: false, count: t.modCount)
        for p in enabled { if let m = t.modIndex[p] { on[m] = true } }
        let avail = t.availability(on)
        let bases = t.scanBases(on, avail)
        var out: [ConflictFinding] = []
        let missing = t.missingDependencies(on, avail, bases)
        out += missing.findings
        out += t.undefinedBaseFindings(on, bases, missing.suggested, missing.folded)
        out += t.baseClassChanges(on, avail)
        out += t.propertyConflicts(on, avail)
        out += t.duplicates(on)
        return out.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            return $0.id < $1.id
        }
    }

    /// Sizes of the precomputed tables, for the test harness.
    var statistics: [String: Int] { t.statistics }

    /// How a class path's base class resolves, step by step (diagnostics).
    func explain(_ path: String) -> [String] { t.explain(path) }

    /// Self-check of the base-class lookup against the base game itself; see `Tables.vanillaResolutionFailures`.
    func vanillaResolutionFailures() -> (checked: Int, failures: [String]) { t.vanillaResolutionFailures() }
}

// MARK: - Tables

private struct Patch {
    let mod: Int32
    let pbo: Int32
    let name: Int32
    let requires: [Int32]
    let skipWhenMissing: Bool
}

private struct PBORef {
    let mod: Int32
    let name: String
    let prefix: String
    let size: Int64
}

/// Bit set over mods.
private struct ModBits {
    var w: [UInt64]
    init(count: Int) { w = [UInt64](repeating: 0, count: (count + 63) / 64) }
    func has(_ i: Int) -> Bool { w[i >> 6] & (1 << UInt64(i & 63)) != 0 }
    mutating func set(_ i: Int) { w[i >> 6] |= 1 << UInt64(i & 63) }
}

/// Which addons end up loaded for an enabled set.
private struct Availability {
    var addon: [Bool]          // by addon id: provided by the base game or an enabled, not skipped, patch
    var patchSkipped: [Bool]   // by patch index: skipWhenMissingDependencies and something it needs is absent
    var pboSkipped: [Bool]     // by pbo index: not loaded as indexed — a patch is skipped, or a __has_include answer changed
    var pboStale: [Bool]       // by pbo index: the config was built for a different set of mods (__has_include)
}

/// A class whose base class is not satisfied by the base game or its own mod.
private struct BaseDemand {
    let mod: Int32
    let pbo: Int32
    let path: Int32
    let base: Int32
    let candidates: [Int32]    // existing paths the lookup finds in the whole library; empty = nowhere
    let declared: Bool         // the mod forward-declares the base (`class Base;`), so the game builds an empty class instead of failing
}

/// A class that several definitions give different bases to.
private struct BaseCandidate {
    let path: Int32
    let vanilla: Int32?        // base the game gives it: name id, -1 = defined without a base; nil = not defined by the game
    let defs: [(mod: Int32, pbo: Int32, base: Int32)]
}

/// One property set to different values by different mods on a class that already exists.
private struct PropCandidate {
    let path: Int32
    let prop: Int32
    let inVanilla: Bool
    let definers: [Int32]      // every mod defining the class
    let entries: [(mod: Int32, pbo: Int32, value: String)]
}

/// Properties that only label who packed a class or when, or what it is called on screen, never how it behaves:
/// two mods setting them differently is visible in a menu at worst. `access` is an enum whose spellings
/// (`0`, `ReadAndWrite`) mean the same.
private let metadataProperties: Set<String> = [
    "timepacked", "author", "authors", "authorurl", "dlc", "access",
    "name", "displayname", "displaynameshort", "descriptionshort", "description", "tooltip", "picture", "icon", "flag",
]

/// Properties whose value changes how something plays; a fight over them counts for more.
private let significantProperties: Set<String> = [
    "armor", "armorstructural", "damage", "hit", "indirecthit", "indirecthitrange", "explosive", "initspeed", "airfriction",
    "caliber", "typicalspeed", "maxspeed", "magazines", "weapons", "muzzles", "ammo", "scope", "scopecurator", "scopearsenal",
    "modelsides", "side", "faction", "model", "mode", "cost", "reloadtime", "dispersion", "recoil", "recoilprone",
    "magazinewell", "count", "mass", "simulation", "soundbullet", "soundsetshot", "sound", "volume", "fuelcapacity", "maxthrust",
]

/// `CfgMods` and `CfgPatches` carry packing metadata and addon bookkeeping, not gameplay config.
private func metadataClass(_ path: String) -> Bool {
    path.hasPrefix("cfgmods") || path.hasPrefix("cfgpatches")
}

/// Legacy registries: `CfgSounds.sounds[]` lists a mod's own sound names and nothing reads it as a setting.
private func registryProperty(_ path: String, _ prop: String) -> Bool { path == "cfgsounds" && prop == "sounds" }

/// Fingerprints compared as written would call `4.0f` (read as an unquoted word) and `4` different.
private func canonicalValue(_ fp: String) -> String {
    guard fp.hasPrefix("\""), fp.hasSuffix("\""), fp.count > 2 else { return fp }
    let inner = fp.dropFirst().dropLast()
    var body = Substring(inner)
    if body.hasSuffix("f") { body = body.dropLast() }
    guard let d = Double(body), d.isFinite else { return fp }
    return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
}

private struct PrefixGroup {
    let prefix: String
    let pbos: [Int32]
}

private struct Tables {
    // Mods
    let modCount: Int
    let modPaths: [String]
    let modNames: [String]
    let modIndex: [String: Int]
    // Addons and patches
    var addonNames: [String] = []
    var addonID: [String: Int32] = [:]
    var addonVanilla: [Bool] = []
    var addonMods: [[Int32]] = []            // mods providing each addon
    var addonPatches: [[Int32]] = []         // patches providing each addon
    var patches: [Patch] = []
    var patchesOfMod: [[Int32]] = []
    var pbos: [PBORef] = []
    var reach: [ModBits] = []                // reach[a] has b: a depends (transitively) on b
    var strictReach: [ModBits] = []          // the same, ignoring requirements the base game fulfils
    // Names and class paths
    var names = NameTable()
    var paths = PathTable()
    // Library-wide class facts
    var demands: [BaseDemand] = []
    var demandsOfMod: [Range<Int>] = []
    var baseCandidates: [BaseCandidate] = []
    var propCandidates: [PropCandidate] = []
    var prefixGroups: [PrefixGroup] = []
    /// PBOs whose configs test `__has_include` for a mod's files: per PBO, for each test that held when the index was
    /// built, the mods that supply the file. The summary is only valid while one of them is enabled.
    var probeMods: [Int32: [[Int32]]] = [:]
    var univ = ClassUniverse()
    /// `class X;` forward declarations: (mod << 32 | path) for every external class a mod writes.
    var declared: Set<UInt64> = []
    var statistics: [String: Int] = [:]

    init(index: GameIndex, names displayNames: [String: String]) {
        let order = index.modOrder.filter { index.mods[$0] != nil }
        modCount = order.count
        modPaths = order
        modNames = order.map { displayNames[$0] ?? URL(fileURLWithPath: $0).lastPathComponent }
        var mi: [String: Int] = [:]
        for (i, p) in order.enumerated() { mi[p] = i }
        modIndex = mi
        buildAddons(index, order)
        buildClasses(index, order)
    }
}

// MARK: Name and path interning

private struct NameTable {
    var strings: [String] = [""]
    var ids: [String: Int32] = ["": 0]
    mutating func id(_ s: String) -> Int32 {
        if let i = ids[s] { return i }
        let i = Int32(strings.count)
        strings.append(s); ids[s] = i
        return i
    }
    func find(_ s: String) -> Int32? { ids[s] }
}

/// Class paths as a tree: id 0 is the config root; `child[(container, name)]` is the member's id.
private struct PathTable {
    var container: [Int32] = [-1]
    var leaf: [Int32] = [0]
    var child: [UInt64: Int32] = [:]
    var count: Int { container.count }

    @inline(__always) static func key(_ c: Int32, _ n: Int32) -> UInt64 { UInt64(UInt32(bitPattern: c)) << 32 | UInt64(UInt32(bitPattern: n)) }

    mutating func member(_ c: Int32, _ n: Int32) -> Int32 {
        let k = PathTable.key(c, n)
        if let i = child[k] { return i }
        let i = Int32(container.count)
        container.append(c); leaf.append(n); child[k] = i
        return i
    }

    /// Interns `a/b/c`, reusing the ids of the components shared with the previous call (configs list a class
    /// right after its container).
    mutating func intern(_ path: String, names: inout NameTable, cache: inout [(String, Int32)]) -> Int32 {
        var depth = 0
        var cur: Int32 = 0
        var result: Int32 = 0
        var s = path
        s.withUTF8 { buf in
            var start = 0
            let n = buf.count
            var reuse = true
            while start <= n {
                var end = start
                while end < n && buf[end] != 0x2F { end += 1 }
                let comp = String(decoding: UnsafeBufferPointer(rebasing: buf[start..<end]), as: UTF8.self)
                if reuse, depth < cache.count, cache[depth].0 == comp {
                    cur = cache[depth].1
                } else {
                    if reuse { cache.removeSubrange(depth...); reuse = false }
                    cur = member(cur, names.id(comp))
                    cache.append((comp, cur))
                }
                depth += 1
                start = end + 1
            }
            result = cur
        }
        if cache.count > depth { cache.removeSubrange(depth...) }
        return result
    }

    func find(_ path: String, _ names: NameTable) -> Int32? {
        var cur: Int32 = 0
        for part in path.lowercased().split(separator: "/") {
            guard let n = names.find(String(part)), let c = child[PathTable.key(cur, n)] else { return nil }
            cur = c
        }
        return cur
    }

    func string(_ p: Int32, _ names: NameTable) -> String {
        var parts: [String] = []
        var c = p
        while c > 0 { parts.append(names.strings[Int(leaf[Int(c)])]); c = container[Int(c)] }
        return parts.reversed().joined(separator: "/")
    }
}

// MARK: - Building

private extension Tables {
    mutating func addon(_ name: String) -> Int32 {
        if let i = addonID[name] { return i }
        let i = Int32(addonNames.count)
        addonNames.append(name); addonID[name] = i
        addonVanilla.append(false); addonMods.append([]); addonPatches.append([])
        return i
    }

    mutating func buildAddons(_ index: GameIndex, _ order: [String]) {
        for a in index.vanilla.addons.sorted() {
            let i = addon(a)
            addonVanilla[Int(i)] = true
        }
        patchesOfMod = [[Int32]](repeating: [], count: modCount)
        for (m, path) in order.enumerated() {
            for pbo in index.mods[path]!.pbos {
                let pi = Int32(pbos.count)
                pbos.append(PBORef(mod: Int32(m), name: pbo.name, prefix: pbo.prefix, size: pbo.size))
                for p in pbo.summary.patches {
                    let name = addon(p.name)
                    let req = p.requiredAddons.map { addon($0) }
                    patchesOfMod[m].append(Int32(patches.count))
                    patches.append(Patch(mod: Int32(m), pbo: pi, name: name, requires: req, skipWhenMissing: p.skipWhenMissingDependencies))
                    addonPatches[Int(name)].append(Int32(patches.count - 1))
                    if !addonMods[Int(name)].contains(Int32(m)) { addonMods[Int(name)].append(Int32(m)) }
                }
            }
        }
        // __has_include tests that depend on which mods are installed.
        var rootMods: [String: [Int32]] = [:]
        for (m, path) in order.enumerated() {
            for pbo in index.mods[path]!.pbos {
                let root = pbo.prefix.isEmpty ? (pbo.name as NSString).deletingPathExtension.lowercased() : pbo.prefix
                if !(rootMods[root]?.contains(Int32(m)) ?? false) { rootMods[root, default: []].append(Int32(m)) }
            }
        }
        var pboNumber: Int32 = 0
        for path in order {
            for pbo in index.mods[path]!.pbos {
                defer { pboNumber += 1 }
                guard pbo.usesHasInclude else { continue }
                var groups: [[Int32]] = []
                for (probe, answer) in pbo.hasIncludeProbes where answer {
                    let comps = probe.split(separator: "\\").map(String.init)
                    var k = comps.count - 1
                    while k >= 1 {
                        if let mods = rootMods[comps[0..<k].joined(separator: "\\")] { groups.append(mods); break }
                        k -= 1
                    }
                }
                if !groups.isEmpty { probeMods[pboNumber] = groups }
            }
        }
        statistics["conditionalPBOs"] = probeMods.count

        // Dependencies between mods, then their transitive closure. `requiredAddons` names addons, so a mod that repacks an addon
        // of the base game under its name (RHS Plus ships an `a3_weapons_f`) is conservatively taken as something every
        // mod requiring that name depends on: it makes mods look related, never unrelated. `strictReach` leaves those
        // out and is only used to pick which mod to blame.
        var edges = [Set<Int32>](repeating: [], count: modCount)
        var strictEdges = [Set<Int32>](repeating: [], count: modCount)
        for p in patches { for r in p.requires { for m in addonMods[Int(r)] where m != p.mod {
            edges[Int(p.mod)].insert(m)
            if !addonVanilla[Int(r)] { strictEdges[Int(p.mod)].insert(m) }
        } } }
        func closure(_ edges: [Set<Int32>]) -> [ModBits] {
            (0..<modCount).map { start in
                var seen = ModBits(count: modCount)
                var stack = [Int32(start)]
                while let x = stack.popLast() { for y in edges[Int(x)] where !seen.has(Int(y)) { seen.set(Int(y)); stack.append(y) } }
                return seen
            }
        }
        reach = closure(edges)
        strictReach = closure(strictEdges)
        // Prefix collisions: the virtual path a PBO's files live under is its prefix (its file name without one).
        var byPrefix: [String: [Int32]] = [:]
        for (i, p) in pbos.enumerated() {
            let key = p.prefix.isEmpty ? (p.name as NSString).deletingPathExtension.lowercased() : p.prefix
            byPrefix[key, default: []].append(Int32(i))
        }
        prefixGroups = byPrefix.filter { Set($0.value.map { pbos[Int($0)].mod }).count > 1 }
            .map { PrefixGroup(prefix: $0.key, pbos: $0.value) }.sorted { $0.prefix < $1.prefix }
        statistics["mods"] = modCount
        statistics["patches"] = patches.count
        statistics["addons"] = addonNames.count
        statistics["prefixGroups"] = prefixGroups.count
    }

    func related(_ a: Int, _ b: Int) -> Bool { reach[a].has(b) || reach[b].has(a) }
}

// MARK: Class tables

/// Everything the class-level analyses share: interned paths, who defines what, how bases resolve.
private struct ClassUniverse {
    var vState: [UInt8] = []               // 0 absent, 1 declared (`class X;`) only, 2 defined — by the base game
    var vBase: [Int32] = []                // base name id of a vanilla definition, -1 none
    var content: [Bool] = []               // a mod defines it with a base, properties or members (not an empty placeholder)
    var uBase: [Int32] = []                // first base name any definition gives it (game first, then mods), -1 none
    var defStart: [Int32] = []             // CSR: defining mods per path
    var defMods: [Int32] = []
    var baseMemo: [Int32] = []             // memo for `baseOf`
    var vanillaMemo: [Int32] = []
    var altBase: [Int32: [Int32]] = [:]    // paths several definitions give different bases: the other base names
    var altMemo: [Int32: [Int32]] = [:]
    var moreBases: [Int32: [Int32]] = [:]  // further places the first base name can mean (same name higher up)

    func definers(_ p: Int32) -> ArraySlice<Int32> { defMods[Int(defStart[Int(p)])..<Int(defStart[Int(p) + 1])] }
}

private extension Tables {
    mutating func buildClasses(_ index: GameIndex, _ order: [String]) {
        var cache: [(String, Int32)] = []
        // 1. Intern the game's classes, then every mod class definition (flat arrays, in library order).
        var vanillaIDs: [(Int32, String)] = []
        vanillaIDs.reserveCapacity(index.vanilla.parents.count)
        for (path, base) in index.vanilla.parents {
            vanillaIDs.append((paths.intern(path, names: &names, cache: &cache), base))
        }
        var dPath: [Int32] = [], dMod: [Int32] = [], dPBO: [Int32] = [], dBase: [Int32] = [], dFull: [Bool] = []
        var pboBase = 0
        for (m, path) in order.enumerated() {
            for pbo in index.mods[path]!.pbos {
                for c in pbo.summary.classes {
                    let id = paths.intern(c.path, names: &names, cache: &cache)
                    if c.external { declared.insert(UInt64(m) << 32 | UInt64(UInt32(bitPattern: id))); continue }
                    dPath.append(id)
                    dMod.append(Int32(m)); dPBO.append(Int32(pboBase))
                    dBase.append(c.parent.map { names.id($0) } ?? -1)
                    dFull.append(c.parent != nil || !c.props.isEmpty || !c.deletes.isEmpty)
                }
                pboBase += 1
            }
        }
        let n = paths.count
        var u = ClassUniverse()
        u.vState = [UInt8](repeating: 0, count: n)
        u.vBase = [Int32](repeating: -1, count: n)
        for (p, base) in vanillaIDs {
            u.vState[Int(p)] = 2
            u.vBase[Int(p)] = base.isEmpty ? -1 : names.id(base)
        }
        for path in index.vanilla.externalOnly { u.vState[Int(paths.intern(path, names: &names, cache: &cache))] = 1 }
        // Defining mods per path (CSR; defs are grouped by mod, so a repeat is the previous entry).
        var count = [Int32](repeating: 0, count: n + 1)
        var lastMod = [Int32](repeating: -1, count: n)
        for k in dPath.indices where lastMod[Int(dPath[k])] != dMod[k] { lastMod[Int(dPath[k])] = dMod[k]; count[Int(dPath[k]) + 1] += 1 }
        for i in 1...n { count[i] += count[i - 1] }
        u.defStart = count
        u.defMods = [Int32](repeating: 0, count: Int(count[n]))
        var fill = [Int32](repeating: 0, count: n)
        lastMod = [Int32](repeating: -1, count: n)
        for k in dPath.indices where lastMod[Int(dPath[k])] != dMod[k] {
            let p = Int(dPath[k]); lastMod[p] = dMod[k]
            u.defMods[Int(u.defStart[p] + fill[p])] = dMod[k]; fill[p] += 1
        }
        u.uBase = u.vBase
        for k in dPath.indices where dBase[k] >= 0 && u.uBase[Int(dPath[k])] < 0 { u.uBase[Int(dPath[k])] = dBase[k] }
        for k in dPath.indices where dBase[k] >= 0 && dBase[k] != u.uBase[Int(dPath[k])] {
            var list = u.altBase[dPath[k]] ?? []
            if !list.contains(dBase[k]) { list.append(dBase[k]); u.altBase[dPath[k]] = list }
        }
        u.content = [Bool](repeating: false, count: n)
        for k in dPath.indices {
            if dFull[k] { u.content[Int(dPath[k])] = true }
            let c = Int(paths.container[Int(dPath[k])])
            if c > 0 { u.content[c] = true }
        }
        u.baseMemo = [Int32](repeating: -2, count: n)
        u.vanillaMemo = [Int32](repeating: -2, count: n)
        statistics["paths"] = n
        statistics["multiBasePaths"] = u.altBase.count
        statistics["modDefs"] = dPath.count

        buildDemands(&u, dPath, dMod, dPBO, dBase)
        buildBaseCandidates(u, dPath, dMod, dPBO, dBase)
        buildPropCandidates(index, order, u, dPath)
        u.baseMemo = []; u.vanillaMemo = []; u.altMemo = [:]; u.moreBases = [:]
        declared = []
        univ = u
    }

    // MARK: Base resolution

    /// The paths a base class name can mean for class `selfPath` in scope `scope`: the member of that name in
    /// the scope, in the scope's own base classes, then outward through the enclosing scopes. `all: false` stops at
    /// the first.
    func lookup(_ u: inout ClassUniverse, scope: Int32, base: Int32, selfPath: Int32, vanillaOnly: Bool, all: Bool) -> [Int32] {
        var found: [Int32] = []
        var x = scope
        while x >= 0 {
            // x and everything it inherits from, nearest first.
            var queue: [Int32] = [x]
            var qi = 0
            while qi < queue.count && qi < 48 {
                let cur = queue[qi]; qi += 1
                if let c = paths.child[PathTable.key(cur, base)], c != selfPath {
                    let ok = vanillaOnly ? u.vState[Int(c)] != 0 : (u.vState[Int(c)] != 0 || u.defStart[Int(c) + 1] > u.defStart[Int(c)])
                    if ok { if !found.contains(c) { found.append(c) }; if !all { return found } }
                }
                for b in basesOf(&u, cur, vanillaOnly: vanillaOnly) where !queue.contains(b) { queue.append(b) }
            }
            x = paths.container[Int(x)]
        }
        return found
    }

    /// Whether `mod` writes `class base;` anywhere the lookup from `scope` would find it: the scope, its base classes,
    /// and outward.
    func declaredInScope(_ u: inout ClassUniverse, mod: Int32, scope: Int32, base: Int32) -> Bool {
        var x = scope
        while x >= 0 {
            var queue: [Int32] = [x]
            var qi = 0
            while qi < queue.count && qi < 48 {
                let cur = queue[qi]; qi += 1
                if let c = paths.child[PathTable.key(cur, base)], declared.contains(UInt64(mod) << 32 | UInt64(UInt32(bitPattern: c))) { return true }
                for b in basesOf(&u, cur, vanillaOnly: false) where !queue.contains(b) { queue.append(b) }
            }
            x = paths.container[Int(x)]
        }
        return false
    }

    /// Where the base classes of `x` live (each `class X: Base` resolved): usually one, several when definitions
    /// disagree about the base; empty when it has none or none can be found.
    func basesOf(_ u: inout ClassUniverse, _ x: Int32, vanillaOnly: Bool) -> [Int32] {
        if x <= 0 { return [] }
        let first = baseOf(&u, x, vanillaOnly: vanillaOnly)
        var out: [Int32] = first >= 0 ? [first] : []
        if first >= 0, let more = u.moreBases[x], !vanillaOnly { out += more }
        if vanillaOnly || u.altBase[x] == nil { return out }
        if let m = u.altMemo[x] { return m }
        u.altMemo[x] = out   // cycle guard
        for name in u.altBase[x]! {
            for r in lookup(&u, scope: paths.container[Int(x)], base: name, selfPath: x, vanillaOnly: false, all: true).prefix(4) where !out.contains(r) { out.append(r) }
        }
        u.altMemo[x] = out
        return out
    }

    /// The base of `x` named by its first definition (the game's, else the first mod's), resolved; -1 when it
    /// has none or cannot be found.
    func baseOf(_ u: inout ClassUniverse, _ x: Int32, vanillaOnly: Bool) -> Int32 {
        if x <= 0 { return -1 }
        let memo = vanillaOnly ? u.vanillaMemo[Int(x)] : u.baseMemo[Int(x)]
        if memo != -2 { return memo }
        if vanillaOnly { u.vanillaMemo[Int(x)] = -1 } else { u.baseMemo[Int(x)] = -1 }   // cycle guard
        var name = vanillaOnly ? u.vBase[Int(x)] : u.uBase[Int(x)]
        // `class Sounds;` with no definition anywhere stands for the member the container inherits.
        let declaredOnly = vanillaOnly ? u.vState[Int(x)] == 1 : (u.vState[Int(x)] == 1 && u.defStart[Int(x) + 1] == u.defStart[Int(x)])
        if name < 0 && declaredOnly { name = paths.leaf[Int(x)] }
        var r: Int32 = -1
        if name >= 0 {
            let found = lookup(&u, scope: paths.container[Int(x)], base: name, selfPath: x, vanillaOnly: vanillaOnly, all: !vanillaOnly)
            r = found.first ?? -1
            if found.count > 1 { u.moreBases[x] = Array(found.dropFirst().prefix(3)) }
        }
        if vanillaOnly { u.vanillaMemo[Int(x)] = r } else { u.baseMemo[Int(x)] = r }
        return r
    }

    mutating func buildDemands(_ u: inout ClassUniverse, _ dPath: [Int32], _ dMod: [Int32], _ dPBO: [Int32], _ dBase: [Int32]) {
        demandsOfMod = [Range<Int>](repeating: 0..<0, count: modCount)
        var start = 0
        var curMod: Int32 = -1
        var local = 0, selfNamed = 0, placeholders = 0
        for k in dPath.indices {
            if dMod[k] != curMod {
                if curMod >= 0 { demandsOfMod[Int(curMod)] = start..<demands.count }
                curMod = dMod[k]; start = demands.count
            }
            let b = dBase[k]
            if b < 0 { continue }
            let p = dPath[k]
            // `class UserActions: UserActions` means "the member my parent has", and the game copes when it has none.
            if b == paths.leaf[Int(p)] { selfNamed += 1; continue }
            let found = lookup(&u, scope: paths.container[Int(p)], base: b, selfPath: p, vanillaOnly: false, all: true)
            let own = found.contains { c in u.vState[Int(c)] != 0 || u.definers(c).contains(dMod[k]) }
            if own { local += 1; continue }
            // The mod forward-declares the base (`class Base;`) where it uses it: the game builds an empty class from that
            // instead of failing, and a mod that does this on purpose is not at fault. Unless a real definition exists in
            // another mod, which is then what the declaration was written for.
            let isDeclared = declaredInScope(&u, mod: dMod[k], scope: paths.container[Int(p)], base: b)
            if isDeclared && !found.contains(where: { u.vState[Int($0)] != 0 || u.content[Int($0)] }) { placeholders += 1; continue }
            demands.append(BaseDemand(mod: dMod[k], pbo: dPBO[k], path: p, base: b, candidates: Array(found.prefix(4)), declared: isDeclared))
        }
        if curMod >= 0 { demandsOfMod[Int(curMod)] = start..<demands.count }
        statistics["selfNamedBases"] = selfNamed
        statistics["declaredPlaceholders"] = placeholders
        statistics["localBases"] = local
        statistics["crossDemands"] = demands.count
        statistics["unresolvableDemands"] = demands.filter { $0.candidates.isEmpty }.count
        statistics["unresolvableSameName"] = demands.filter { $0.candidates.isEmpty && $0.base == paths.leaf[Int($0.path)] }.count
    }

    mutating func buildBaseCandidates(_ u: ClassUniverse, _ dPath: [Int32], _ dMod: [Int32], _ dPBO: [Int32], _ dBase: [Int32]) {
        var seen: [(path: Int32, mod: Int32, pbo: Int32, base: Int32)] = []
        for k in dPath.indices where dBase[k] >= 0 {
            let p = Int(dPath[k])
            if u.vState[p] == 2 || u.defStart[p + 1] - u.defStart[p] > 1 { seen.append((dPath[k], dMod[k], dPBO[k], dBase[k])) }
        }
        seen.sort { $0.path != $1.path ? $0.path < $1.path : ($0.mod, $0.pbo) < ($1.mod, $1.pbo) }
        var i = 0
        while i < seen.count {
            var j = i
            while j < seen.count && seen[j].path == seen[i].path { j += 1 }
            let p = seen[i].path
            var defs: [(mod: Int32, pbo: Int32, base: Int32)] = []
            for k in i..<j where !defs.contains(where: { $0.pbo == seen[k].pbo && $0.base == seen[k].base }) { defs.append((seen[k].mod, seen[k].pbo, seen[k].base)) }
            let van: Int32? = u.vState[Int(p)] == 2 ? u.vBase[Int(p)] : nil
            let distinct = Set(defs.map(\.base)).union(van.map { $0 >= 0 ? [$0] : [] } ?? [])
            let differsFromGame = van != nil && defs.contains { $0.base != van! }
            if distinct.count > 1 || differsFromGame { baseCandidates.append(BaseCandidate(path: p, vanilla: van, defs: defs)) }
            i = j
        }
        statistics["baseCandidates"] = baseCandidates.count
    }

    mutating func buildPropCandidates(_ index: GameIndex, _ order: [String], _ u: ClassUniverse, _ dPath: [Int32]) {
        struct Rec { let key: UInt64; let mod: Int32; let pbo: Int32; let value: String }
        var recs: [Rec] = []
        var k = 0
        var pboIndex: Int32 = 0
        for (m, path) in order.enumerated() {
            for pbo in index.mods[path]!.pbos {
                defer { pboIndex += 1 }
                for c in pbo.summary.classes where !c.external {
                    defer { k += 1 }
                    if c.props.isEmpty { continue }
                    let p = dPath[k]
                    let ndef = Int(u.defStart[Int(p) + 1] - u.defStart[Int(p)])
                    // Only classes that exist before the contenders: in the game, or defined by at least three mods.
                    guard u.vState[Int(p)] == 2 || ndef >= 3 else { continue }
                    if metadataClass(paths.string(p, names)) { continue }
                    let cls = paths.string(p, names)
                    for (name, value) in c.props where !value.hasPrefix("+=") && !metadataProperties.contains(name) && !registryProperty(cls, name) {
                        recs.append(Rec(key: PathTable.key(p, names.id(name)), mod: Int32(m), pbo: pboIndex, value: canonicalValue(value)))
                    }
                }
            }
        }
        recs.sort { $0.key != $1.key ? $0.key < $1.key : ($0.mod, $0.pbo) < ($1.mod, $1.pbo) }
        var i = 0
        while i < recs.count {
            var j = i
            while j < recs.count && recs[j].key == recs[i].key { j += 1 }
            if j - i > 1 {
                var entries: [(mod: Int32, pbo: Int32, value: String)] = []
                for q in i..<j where !entries.contains(where: { $0.pbo == recs[q].pbo }) { entries.append((recs[q].mod, recs[q].pbo, recs[q].value)) }
                if Set(entries.map(\.mod)).count > 1, Set(entries.map(\.value)).count > 1 {
                    let p = Int32(truncatingIfNeeded: recs[i].key >> 32)
                    propCandidates.append(PropCandidate(path: p, prop: Int32(truncatingIfNeeded: recs[i].key & 0xFFFF_FFFF),
                                                        inVanilla: u.vState[Int(p)] == 2, definers: Array(u.definers(p)), entries: entries))
                }
            }
            i = j
        }
        statistics["propCandidates"] = propCandidates.count
    }
}


// MARK: - Analyses

/// How the cross-mod base-class demands fare for an enabled set.
private struct BaseScan {
    /// Per mod: demands (indexes into `demands`) whose base exists nowhere installed, or only in disabled mods
    /// (grouped by the disabled mod that is the best one to turn on).
    var nowhere: [Int32: [Int]] = [:]
    var disabled: [Int32: [Int32: [Int]]] = [:]
}

private func countedNoun(_ n: Int, _ one: String, _ many: String? = nil) -> String { n == 1 ? "1 \(one)" : "\(n) \(many ?? one + "s")" }

private func clipped(_ s: String, _ n: Int = 60) -> String { s.count <= n ? s : String(s.prefix(n - 1)) + "…" }

/// Evidence list capped at `limit` lines plus a line counting the rest.
private func cappedLines(_ lines: [String], _ limit: Int = 6) -> [String] {
    lines.count <= limit ? lines : Array(lines.prefix(limit)) + ["… and \(lines.count - limit) more"]
}

private struct ModPair: Hashable {
    let a: Int32
    let b: Int32
    init(_ x: Int32, _ y: Int32) { a = min(x, y); b = max(x, y) }
}

private extension Tables {
    func name(_ m: Int) -> String { modNames[m] }
    func name(_ m: Int32) -> String { modNames[Int(m)] }
    func list(_ ms: [Int32], limit: Int = 3) -> String {
        let n = ms.map { name($0) }
        return n.count <= limit ? n.joined(separator: ", ") : n.prefix(limit).joined(separator: ", ") + " and \(n.count - limit) more"
    }
    func cls(_ p: Int32) -> String { paths.string(p, names) }
    func word(_ id: Int32) -> String { id < 0 ? "(none)" : names.strings[Int(id)] }
}

extension Tables {
    // MARK: Which addons load

    fileprivate func availability(_ on: [Bool]) -> Availability {
        var addon = addonVanilla
        var live = [Int32](repeating: 0, count: addonNames.count)
        var skipped = [Bool](repeating: false, count: patches.count)
        var mine: [Int] = []
        for m in 0..<modCount where on[m] { mine += patchesOfMod[m].map { Int($0) } }
        for i in mine { let n = Int(patches[i].name); live[n] += 1; addon[n] = true }
        var changed = true
        while changed {
            changed = false
            for i in mine where patches[i].skipWhenMissing && !skipped[i] && patches[i].requires.contains(where: { !addon[Int($0)] }) {
                skipped[i] = true; changed = true
                let n = Int(patches[i].name)
                live[n] -= 1
                if live[n] == 0 && !addonVanilla[n] { addon[n] = false }
            }
        }
        var pboSkipped = [Bool](repeating: false, count: pbos.count)
        var pboStale = [Bool](repeating: false, count: pbos.count)
        for i in mine where skipped[i] { pboSkipped[Int(patches[i].pbo)] = true }
        for (pbo, groups) in probeMods where on[Int(pbos[Int(pbo)].mod)] && groups.contains(where: { g in !g.contains { on[Int($0)] } }) {
            pboStale[Int(pbo)] = true; pboSkipped[Int(pbo)] = true
        }
        return Availability(addon: addon, patchSkipped: skipped, pboSkipped: pboSkipped, pboStale: pboStale)
    }

    // MARK: Base classes

    fileprivate func scanBases(_ on: [Bool], _ avail: Availability) -> BaseScan {
        var scan = BaseScan()
        for m in 0..<modCount where on[m] {
            for di in demandsOfMod[m] {
                let d = demands[di]
                if avail.pboSkipped[Int(d.pbo)] { continue }
                if d.candidates.isEmpty { scan.nowhere[d.mod, default: []].append(di); continue }
                var satisfied = false
                var off: [Int32] = []
                for c in d.candidates {
                    if univ.vState[Int(c)] != 0 { satisfied = true; break }
                    for p in univ.definers(c) {
                        if on[Int(p)] { satisfied = true }       // loaded somewhere; whether before this mod is up to the engine
                        else if univ.content[Int(c)] && !off.contains(p) { off.append(p) }   // an empty placeholder is not worth turning a mod on for
                    }
                    if satisfied { break }
                }
                if satisfied { continue }
                // Several disabled mods may define the same base (copies); name the one the others build on.
                guard let best = off.max(by: { a, b in
                    let ka = (strictReach[m].has(Int(a)) ? 1000 : 0) + off.filter { strictReach[Int($0)].has(Int(a)) }.count
                    let kb = (strictReach[m].has(Int(b)) ? 1000 : 0) + off.filter { strictReach[Int($0)].has(Int(b)) }.count
                    return ka != kb ? ka < kb : a > b
                }) else { scan.nowhere[d.mod, default: []].append(di); continue }
                scan.disabled[d.mod, default: [:]][best, default: []].append(di)
            }
        }
        return scan
    }

    private func baseEvidence(_ ds: [Int]) -> [String] {
        var byBase: [Int32: [Int]] = [:]
        for di in ds { byBase[demands[di].base, default: []].append(di) }
        return byBase.sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : word($0.key) < word($1.key) }
            .map { b, list in
                let first = list.map { cls(demands[$0].path) }.min()!
                return "base '\(word(b))' not found: \(countedNoun(list.count, "class", "classes")), e.g. \(first)"
            }
    }

    // MARK: Missing dependencies

    fileprivate func missingDependencies(_ on: [Bool], _ avail: Availability, _ bases: BaseScan) -> (findings: [ConflictFinding], suggested: [Int32: Set<Int32>], folded: Set<Int32>) {
        var out: [ConflictFinding] = []
        var suggested: [Int32: Set<Int32>] = [:]
        var folded = Set<Int32>()
        for m in 0..<modCount where on[m] {
            var needed: [Int32: [String]] = [:]   // missing addon → patches of this mod that need it
            var via: [Int32: String] = [:]        // missing addon → the skipped addon that needed it
            for pi in patchesOfMod[m] where !avail.patchSkipped[Int(pi)] && !avail.pboStale[Int(patches[Int(pi)].pbo)] {
                let p = patches[Int(pi)]
                for r in p.requires where !avail.addon[Int(r)] {
                    // An enabled mod does provide it, but that addon is skipped for lack of its own requirements:
                    // those are the real gap, and a disabled copy of the addon would be skipped too.
                    let skippedProviders = addonPatches[Int(r)].map { Int($0) }.filter { on[Int(patches[$0].mod)] && avail.patchSkipped[$0] }
                    if skippedProviders.isEmpty { needed[r, default: []].append(addonNames[Int(p.name)]); continue }
                    for sp in skippedProviders { for rr in patches[sp].requires where !avail.addon[Int(rr)] {
                        needed[rr, default: []].append(addonNames[Int(p.name)])
                        via[rr] = addonNames[Int(r)]
                    } }
                }
            }
            if needed.isEmpty { continue }
            let missing = needed.keys.sorted { addonNames[Int($0)] < addonNames[Int($1)] }
            // Installed-but-disabled providers, chosen greedily by how many missing addons they cover.
            var uncovered = Set(missing)
            var chosen: [Int32] = []
            var providerOf: [Int32: [Int32]] = [:]
            for r in missing { providerOf[r] = addonMods[Int(r)].filter { !on[Int($0)] } }
            while true {
                var tally: [Int32: Int] = [:]
                for r in uncovered { for p in providerOf[r] ?? [] { tally[p, default: 0] += 1 } }
                guard let best = tally.max(by: { a, b in
                    if a.value != b.value { return a.value < b.value }
                    // Same coverage: prefer the smaller mod, i.e. the standalone part over a bundle that also ships it.
                    let sa = patchesOfMod[Int(a.key)].count, sb = patchesOfMod[Int(b.key)].count
                    return sa != sb ? sa > sb : a.key > b.key
                }) else { break }
                chosen.append(best.key)
                uncovered = uncovered.filter { !(providerOf[$0] ?? []).contains(best.key) }
            }
            var dlc: [String: [Int32]] = [:]
            var unknown: [Int32] = []
            var skippedProviders: [Int32] = []
            for r in uncovered {
                if addonMods[Int(r)].contains(where: { on[Int($0)] }) { skippedProviders.append(r) }
                else if let info = KnownIssues.creatorDLCInfo(forAddon: addonNames[Int(r)]) { dlc[info.name, default: []].append(r) }
                else { unknown.append(r) }
            }
            suggested[Int32(m)] = Set(chosen)
            if !dlc.isEmpty || !unknown.isEmpty { folded.insert(Int32(m)) }

            var evidence: [String] = []
            for r in missing {
                let a = addonNames[Int(r)]
                let who = needed[r]!.prefix(2).joined(separator: ", ") + (needed[r]!.count > 2 ? " +\(needed[r]!.count - 2)" : "")
                var line = "addon '\(a)' (required by \(who))"
                if let v = via[r] { line = "addon '\(a)' (needed by '\(v)', which is skipped without it, and so by \(who))" + (providerOf[r].map { $0.isEmpty ? " is provided by no installed mod or the base game" : " is in \(list($0, limit: 2)), which is turned off" } ?? "") }
                else if let p = providerOf[r], !p.isEmpty { line += " is in \(list(p, limit: 2)), which is turned off" }
                else if skippedProviders.contains(r) { line += " is in an enabled mod whose addon is skipped because its own requirements are missing" }
                else if let info = KnownIssues.creatorDLCInfo(forAddon: a) { line += " belongs to the \(info.name) Creator DLC" }
                else { line += " is provided by no installed mod or the base game" }
                evidence.append(line)
            }
            for p in chosen {
                if let ds = bases.disabled[Int32(m)]?[p] {
                    evidence.append("\(countedNoun(ds.count, "class", "classes")) of \(name(m)) extend classes defined by \(name(p)) (e.g. \(cls(demands[ds[0]].path)) extends '\(word(demands[ds[0]].base))')")
                }
            }
            if folded.contains(Int32(m)), let ds = bases.nowhere[Int32(m)] {
                evidence.append("\(countedNoun(ds.count, "class", "classes")) extend classes that exist in no installed mod, probably the ones from the missing addons (e.g. \(cls(demands[ds[0]].path)) extends '\(word(demands[ds[0]].base))')")
            }
            var parts: [String] = []
            if !chosen.isEmpty { parts.append("Turn on \(list(chosen)).") }
            for (n, rs) in dlc.sorted(by: { $0.key < $1.key }) {
                parts.append("It needs the \(n) Creator DLC (or its free compatibility data) for \(rs.map { addonNames[Int($0)] }.sorted().prefix(3).joined(separator: ", ")).")
            }
            if !unknown.isEmpty {
                parts.append("No installed mod provides \(unknown.map { addonNames[Int($0)] }.sorted().prefix(3).joined(separator: ", "))\(unknown.count > 3 ? " and \(unknown.count - 3) more" : ""); subscribe to what its Workshop page lists as required, or the mod is out of date for the version installed.")
            }
            if !skippedProviders.isEmpty { parts.append("\(countedNoun(skippedProviders.count, "required addon")) comes from an enabled mod that is itself skipped.") }
            let title: String
            if chosen.count == 1 && uncovered.isEmpty { title = "\(name(m)) needs \(name(chosen[0])), which is turned off" }
            else if chosen.isEmpty && dlc.count == 1 && unknown.isEmpty && skippedProviders.isEmpty { title = "\(name(m)) needs the \(dlc.keys.first!) Creator DLC" }
            else { title = "\(name(m)) is missing \(countedNoun(missing.count, "required addon"))" }
            out.append(ConflictFinding(
                kind: .missingDependency, severity: .error, modPaths: [modPaths[m]] + chosen.map { modPaths[Int($0)] },
                title: title,
                detail: "Arma 3 warns \"Addon X requires addon Y\" at startup, and without it the load order is not guaranteed, so what this mod inherits from the missing addon is not there. " + parts.joined(separator: " "),
                evidence: cappedLines(evidence), confidence: uncovered.isEmpty ? 0.97 : 0.92,
                suggestedEnable: chosen.map { modPaths[Int($0)] }, suggestedDisable: []))
        }
        return (out, suggested, folded)
    }

    fileprivate func undefinedBaseFindings(_ on: [Bool], _ bases: BaseScan, _ suggested: [Int32: Set<Int32>], _ folded: Set<Int32>) -> [ConflictFinding] {
        var out: [ConflictFinding] = []
        for (mod, ds) in bases.nowhere.sorted(by: { $0.key < $1.key }) where !folded.contains(mod) {
            let m = Int(mod)
            // Without a mod to blame this is the mod's own config error: noisy in the log, rarely visible in play.
            out.append(ConflictFinding(
                kind: .undefinedBaseClass, severity: .info, modPaths: [modPaths[m]],
                title: "\(name(m)): \(countedNoun(ds.count, "class", "classes")) inherit\(ds.count == 1 ? "s" : "") from a class that does not exist",
                detail: "The base classes are in neither the base game nor any installed mod, and the mod does not declare them, so these classes lose what they should inherit and Arma logs config errors. The mod's config is at fault, or it needs a mod that is not installed.",
                evidence: cappedLines(baseEvidence(ds)), confidence: 0.6, suggestedEnable: [], suggestedDisable: []))
        }
        for (mod, byProvider) in bases.disabled.sorted(by: { $0.key < $1.key }) {
            let m = Int(mod)
            for (p, ds) in byProvider.sorted(by: { $0.key < $1.key }) where !(suggested[mod]?.contains(p) ?? false) {
                // Declared bases become empty classes: the objects are broken but the game raises no config error.
                let soft = ds.allSatisfy { demands[$0].declared }
                out.append(ConflictFinding(
                    kind: .undefinedBaseClass, severity: soft ? .warning : .error, modPaths: [modPaths[m], modPaths[Int(p)]],
                    title: "\(name(m)) needs classes from \(name(p)), which is turned off",
                    detail: "\(countedNoun(ds.count, "class", "classes")) of \(name(m)) extend classes that only \(name(p)) (of the mods installed) defines, so they lose what they should inherit. "
                        + (soft ? "The mod declares those bases, so the game builds empty ones and the config raises no error, but the objects are broken." : "Arma logs a config error for each."),
                    evidence: cappedLines(baseEvidence(ds)), confidence: soft ? 0.7 : 0.85,
                    suggestedEnable: [modPaths[Int(p)]], suggestedDisable: []))
            }
        }
        return out
    }

    // MARK: Base-class changes

    fileprivate func baseClassChanges(_ on: [Bool], _ avail: Availability) -> [ConflictFinding] {
        struct Row { let path: Int32; let base: Int32; let game: Int32; let keepers: [Int32] }
        var deviant: [Int32: [Row]] = [:]
        var pairRows: [ModPair: [String]] = [:]
        var pairCount: [ModPair: Int] = [:]
        var intended: [Int32: [String]] = [:]
        var intendedCount: [Int32: Int] = [:]

        for c in baseCandidates {
            var defs: [(mod: Int32, base: Int32)] = []
            let own = paths.leaf[Int(c.path)]
            // `class EventHandlers: EventHandlers` inherits the parent's member of that name; it names no new base.
            for d in c.defs where d.base != own && on[Int(d.mod)] && !avail.pboSkipped[Int(d.pbo)] && !defs.contains(where: { $0.mod == d.mod && $0.base == d.base }) { defs.append((d.mod, d.base)) }
            if defs.isEmpty { continue }
            // Who disagrees with whom: unrelated mods only, and not when a mod that depends on both decides.
            var rivals: [Int32: [Int32]] = [:]
            for i in 0..<defs.count { for j in (i + 1)..<defs.count where defs[i].base != defs[j].base {
                let (a, b) = (defs[i], defs[j])
                if a.mod == b.mod || related(Int(a.mod), Int(b.mod)) { continue }
                if defs.contains(where: { $0.mod != a.mod && $0.mod != b.mod && reach[Int($0.mod)].has(Int(a.mod)) && reach[Int($0.mod)].has(Int(b.mod)) }) { continue }
                rivals[a.mod, default: []].append(b.mod); rivals[b.mod, default: []].append(a.mod)
            } }
            let baseOfMod = Dictionary(defs.map { ($0.mod, $0.base) }, uniquingKeysWith: { a, _ in a })
            var paired = Set<ModPair>()
            for d in defs {
                let others = rivals[d.mod] ?? []
                if let g = c.vanilla, d.base != g {
                    let keepers = others.filter { baseOfMod[$0] == g }
                    if !keepers.isEmpty { deviant[d.mod, default: []].append(Row(path: c.path, base: d.base, game: g, keepers: keepers)) }
                    else if others.isEmpty {
                        // `class AnimationSources: AnimationSources` on a class that had no base is just inheriting the parent's member.
                        if g < 0 && word(d.base) == word(paths.leaf[Int(c.path)]) { continue }
                        intendedCount[d.mod, default: 0] += 1
                        if (intended[d.mod]?.count ?? 0) < 12 { intended[d.mod, default: []].append("\(cls(c.path)): '\(word(g))' → '\(word(d.base))'") }
                    }
                    for o in others where baseOfMod[o] != g { paired.insert(ModPair(d.mod, o)) }
                } else if c.vanilla == nil {
                    for o in others { paired.insert(ModPair(d.mod, o)) }
                }
            }
            for pr in paired {
                pairCount[pr, default: 0] += 1
                if (pairRows[pr]?.count ?? 0) < 12 {
                    pairRows[pr, default: []].append("\(cls(c.path)): \(name(pr.a)) says '\(word(baseOfMod[pr.a] ?? -1))', \(name(pr.b)) says '\(word(baseOfMod[pr.b] ?? -1))'" + (c.vanilla.map { " (game: '\(word($0))')" } ?? ""))
                }
            }
        }

        var out: [ConflictFinding] = []
        for (mod, rows) in deviant.sorted(by: { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }) {
            let keepers = Array(Set(rows.flatMap(\.keepers))).sorted { name($0) < name($1) }
            let lines = rows.sorted { cls($0.path) < cls($1.path) }.map { r -> String in
                let who = Array(Set(r.keepers))
                return "\(cls(r.path)): \(name(mod)) says '\(word(r.base))'; the game" + (who.isEmpty ? "" : " and \(list(who, limit: 2))") + " say '\(word(r.game))'"
            }
            out.append(ConflictFinding(
                kind: .baseClassChange, severity: .warning, modPaths: [modPaths[Int(mod)]] + keepers.prefix(4).map { modPaths[Int($0)] },
                title: "\(name(mod)) changes the base class of \(countedNoun(rows.count, "class", "classes")) that \(keepers.count == 1 ? "another mod keeps" : "other mods keep")",
                detail: "Arma logs \"Updating base class\" when a config names a different base for an existing class. \(list(keepers, limit: 3)) \(keepers.count == 1 ? "does" : "do") not depend on \(name(mod)) and name the original base, so whichever loads last decides, and the loser's version of these classes inherits the wrong things.",
                evidence: cappedLines(lines), confidence: 0.7, suggestedEnable: [], suggestedDisable: []))
        }
        for (pr, n) in pairCount.sorted(by: { $0.value != $1.value ? $0.value > $1.value : ($0.key.a, $0.key.b) < ($1.key.a, $1.key.b) }) {
            out.append(ConflictFinding(
                kind: .baseClassChange, severity: .warning, modPaths: [modPaths[Int(pr.a)], modPaths[Int(pr.b)]],
                title: "\(name(pr.a)) and \(name(pr.b)) disagree on the base class of \(countedNoun(n, "class", "classes"))",
                detail: "Neither mod depends on the other, so whichever loads last decides the base class (Arma logs \"Updating base class\").",
                evidence: cappedLines(pairRows[pr]!), confidence: 0.7, suggestedEnable: [], suggestedDisable: []))
        }
        for (mod, n) in intendedCount.sorted(by: { $0.key < $1.key }) {
            out.append(ConflictFinding(
                kind: .baseClassChange, severity: .info, modPaths: [modPaths[Int(mod)]],
                title: "\(name(mod)) changes the base class of \(countedNoun(n, "existing class", "existing classes"))",
                detail: "Arma logs \"Updating base class\" for each. No other enabled mod names a different base for them, so this is just the mod reworking the original.",
                evidence: cappedLines(intended[mod]!, 4), confidence: 0.9, suggestedEnable: [], suggestedDisable: []))
        }
        return out
    }

    // MARK: Property fights

    fileprivate func propertyConflicts(_ on: [Bool], _ avail: Availability) -> [ConflictFinding] {
        struct Example { let score: Int; let text: String }
        var score: [ModPair: Int] = [:]
        var count: [ModPair: Int] = [:]
        var classes: [ModPair: Set<Int32>] = [:]
        var examples: [ModPair: [Example]] = [:]
        var signature: [ModPair: [Int32]] = [:]       // candidates the pair fights over
        for (ci, c) in propCandidates.enumerated() {
            let es = c.entries.filter { on[Int($0.mod)] && !avail.pboSkipped[Int($0.pbo)] }
            if es.count < 2 { continue }
            let prop = names.strings[Int(c.prop)]
            let weight = significantProperties.contains(prop) ? 3 : 1
            var counted = Set<ModPair>()
            for i in 0..<es.count { for j in (i + 1)..<es.count where es[i].value != es[j].value && es[i].mod != es[j].mod {
                let (a, b) = (es[i], es[j])
                if !counted.insert(ModPair(a.mod, b.mod)).inserted { continue }
                if related(Int(a.mod), Int(b.mod)) { continue }
                // The class must predate both contenders: in the base game, or defined by a mod one of them builds on.
                if !c.inVanilla && !c.definers.contains(where: { on[Int($0)] && $0 != a.mod && $0 != b.mod && (reach[Int(a.mod)].has(Int($0)) || reach[Int(b.mod)].has(Int($0))) }) { continue }
                // A mod that depends on both settles it.
                if es.contains(where: { $0.mod != a.mod && $0.mod != b.mod && reach[Int($0.mod)].has(Int(a.mod)) && reach[Int($0.mod)].has(Int(b.mod)) }) { continue }
                let pr = ModPair(a.mod, b.mod)
                let (x, y) = a.mod == pr.a ? (a, b) : (b, a)
                score[pr, default: 0] += weight
                count[pr, default: 0] += 1
                classes[pr, default: []].insert(c.path)
                signature[pr, default: []].append(Int32(ci))
                var list = examples[pr] ?? []
                if list.count < 24 {
                    list.append(Example(score: weight * 2 + (c.inVanilla ? 1 : 0),
                                        text: "\(cls(c.path)).\(prop): \(name(x.mod)) = \(clipped(x.value)), \(name(y.mod)) = \(clipped(y.value))"))
                    examples[pr] = list
                }
            } }
        }
        let shown = score.filter { $0.value >= 3 }.keys.sorted { ($0.a, $0.b) < ($1.a, $1.b) }

        // One mod fighting many others over exactly the same settings (a lone outlier) is one finding about that mod.
        var bySignature: [[Int32]: [ModPair]] = [:]
        for pr in shown { bySignature[signature[pr]!, default: []].append(pr) }
        var merged = Set<ModPair>()
        var out: [ConflictFinding] = []
        for (sig, prs) in bySignature.sorted(by: { ($0.value[0].a, $0.value[0].b) < ($1.value[0].a, $1.value[0].b) }) {
            var rest = prs
            while true {
                var degree: [Int32: Int] = [:]
                for pr in rest { degree[pr.a, default: 0] += 1; degree[pr.b, default: 0] += 1 }
                guard let hub = degree.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }), hub.value >= 3 else { break }
                let mine = rest.filter { $0.a == hub.key || $0.b == hub.key }
                rest.removeAll { $0.a == hub.key || $0.b == hub.key }
                let partners = mine.map { $0.a == hub.key ? $0.b : $0.a }.sorted { name($0) < name($1) }
                for pr in mine { merged.insert(pr) }
                var lines: [Example] = []
                for ci in sig {
                    let c = propCandidates[Int(ci)]
                    guard let mineEntry = c.entries.first(where: { $0.mod == hub.key && on[Int($0.mod)] && !avail.pboSkipped[Int($0.pbo)] }) else { continue }
                    let others = c.entries.filter { partners.contains($0.mod) && on[Int($0.mod)] && !avail.pboSkipped[Int($0.pbo)] && $0.value != mineEntry.value }
                    let w = significantProperties.contains(names.strings[Int(c.prop)]) ? 3 : 1
                    let who = list(Array(Set(others.map(\.mod))).sorted(), limit: 2)
                    lines.append(Example(score: w * 2 + (c.inVanilla ? 1 : 0),
                                         text: "\(cls(c.path)).\(names.strings[Int(c.prop)]): \(name(hub.key)) = \(clipped(mineEntry.value)); \(who) = \(clipped(others.first?.value ?? ""))"))
                }
                let s = score[mine[0]]!, n = count[mine[0]]!, k = classes[mine[0]]!.count
                out.append(ConflictFinding(
                    kind: .propertyConflict, severity: s >= 10 ? .warning : .info, modPaths: [modPaths[Int(hub.key)]] + partners.prefix(5).map { modPaths[Int($0)] },
                    title: "\(name(hub.key)) sets \(countedNoun(n, "setting")) of \(countedNoun(k, "class", "classes")) differently from \(countedNoun(partners.count, "other mod"))",
                    detail: "\(list(partners, limit: 3)) and \(name(hub.key)) do not depend on each other, so for each of these the value of whichever loads last wins.",
                    evidence: cappedLines(lines.sorted { $0.score != $1.score ? $0.score > $1.score : $0.text < $1.text }.map(\.text)),
                    confidence: s >= 10 ? 0.7 : 0.55, suggestedEnable: [], suggestedDisable: []))
            }
        }
        for pr in shown where !merged.contains(pr) {
            let s = score[pr]!, n = count[pr]!, k = classes[pr]!.count
            out.append(ConflictFinding(
                kind: .propertyConflict, severity: s >= 10 ? .warning : .info, modPaths: [modPaths[Int(pr.a)], modPaths[Int(pr.b)]],
                title: "\(name(pr.a)) and \(name(pr.b)) both change \(countedNoun(n, "setting")) of \(countedNoun(k, "class", "classes"))",
                detail: "Neither mod depends on the other, so for each of these the value of whichever loads last wins and the other mod's tuning is lost.",
                evidence: cappedLines(examples[pr]!.sorted { $0.score != $1.score ? $0.score > $1.score : $0.text < $1.text }.map(\.text)),
                confidence: s >= 10 ? 0.7 : 0.55, suggestedEnable: [], suggestedDisable: []))
        }
        return out
    }

    // MARK: Duplicates

    fileprivate func duplicates(_ on: [Bool]) -> [ConflictFinding] {
        // Shared addon names per pair of enabled mods, and whether the providing PBOs are the same file.
        struct Shared { var addons: [Int32] = []; var identical = true }
        var shared: [ModPair: Shared] = [:]
        var pboOf: [Int32: [Int32: Int32]] = [:]   // addon → mod → pbo
        for m in 0..<modCount where on[m] { for pi in patchesOfMod[m] { pboOf[patches[Int(pi)].name, default: [:]][Int32(m)] = patches[Int(pi)].pbo } }
        for (ai, mods) in addonMods.enumerated() {
            let live = mods.filter { on[Int($0)] }
            if live.count < 2 { continue }
            for i in 0..<live.count { for j in (i + 1)..<live.count {
                let pr = ModPair(live[i], live[j])
                var s = shared[pr] ?? Shared()
                s.addons.append(Int32(ai))
                if let x = pboOf[Int32(ai)]?[pr.a], let y = pboOf[Int32(ai)]?[pr.b] {
                    let (p, q) = (pbos[Int(x)], pbos[Int(y)])
                    if p.size != q.size || p.name.lowercased() != q.name.lowercased() { s.identical = false }
                }
                shared[pr] = s
            } }
        }
        func addonSet(_ m: Int32) -> Set<Int32> { Set(patchesOfMod[Int(m)].map { patches[Int($0)].name }) }
        var out: [ConflictFinding] = []
        var explained = Set<ModPair>()
        var parts: [Int32: [Int32]] = [:]     // container mod → mods it wholly contains as identical copies
        for (pr, s) in shared.sorted(by: { ($0.key.a, $0.key.b) < ($1.key.a, $1.key.b) }) {
            explained.insert(pr)
            let (sa, sb) = (addonSet(pr.a), addonSet(pr.b)), common = Set(s.addons)
            if s.identical && common == sa && sa.count < sb.count { parts[pr.b, default: []].append(pr.a); continue }
            if s.identical && common == sb && sb.count < sa.count { parts[pr.a, default: []].append(pr.b); continue }
            let names = s.addons.map { addonNames[Int($0)] }.sorted()
            let how = s.identical ? "The PBOs are the same files, so these are copies." : "The PBOs differ, so these are different versions of the same addons and only one can win."
            let equal = common == sa && common == sb
            out.append(ConflictFinding(
                kind: .duplicateAddon, severity: .warning, modPaths: [modPaths[Int(pr.a)], modPaths[Int(pr.b)]],
                title: equal ? "\(name(pr.a)) and \(name(pr.b)) are the same addons" : "\(name(pr.a)) and \(name(pr.b)) share \(countedNoun(names.count, "addon"))",
                detail: "Both mods provide addons with the same CfgPatches names (\(sa.count) and \(sb.count) addons in total), so their configs merge and one mod's files shadow the other's. " + how,
                evidence: cappedLines(names.map { "addon '\($0)' is in both" }), confidence: s.identical ? 0.9 : 0.8,
                suggestedEnable: [], suggestedDisable: []))
        }
        for (whole, list) in parts.sorted(by: { $0.key < $1.key }) {
            let sorted = list.sorted { name($0) < name($1) }
            out.append(ConflictFinding(
                kind: .duplicateAddon, severity: .warning, modPaths: [modPaths[Int(whole)]] + sorted.map { modPaths[Int($0)] },
                title: "\(name(whole)) already contains \(sorted.count == 1 ? name(sorted[0]) : countedNoun(sorted.count, "other enabled mod"))",
                detail: "Every addon of \(sorted.count == 1 ? "that mod" : "those mods") is in \(name(whole)) as the same file, so keeping both only loads the addons twice.",
                evidence: cappedLines(sorted.map { m in "\(name(m)): \(countedNoun(addonSet(m).count, "addon")), all also in \(name(whole))" }),
                confidence: 0.9, suggestedEnable: [], suggestedDisable: sorted.map { modPaths[Int($0)] }))
        }
        // PBOs mounted at the same virtual path.
        for g in prefixGroups {
            let live = g.pbos.filter { on[Int(pbos[Int($0)].mod)] }
            let mods = Array(Set(live.map { pbos[Int($0)].mod })).sorted()
            if mods.count < 2 { continue }
            for i in 0..<mods.count { for j in (i + 1)..<mods.count {
                let pr = ModPair(mods[i], mods[j])
                if explained.contains(pr) { continue }
                let pa = pbos[Int(live.first { pbos[Int($0)].mod == pr.a }!)], pb = pbos[Int(live.first { pbos[Int($0)].mod == pr.b }!)]
                let same = pa.size == pb.size && pa.name.lowercased() == pb.name.lowercased()
                out.append(ConflictFinding(
                    kind: .prefixCollision, severity: same ? .info : .warning, modPaths: [modPaths[Int(pr.a)], modPaths[Int(pr.b)]],
                    title: "\(name(pr.a)) and \(name(pr.b)) both mount files at '\(g.prefix)'",
                    detail: same ? "Both ship the same PBO, so nothing is lost, but it is loaded twice."
                        : "Both mods ship files under the same virtual path but the PBOs differ, so one mod's files shadow the other's and it can load the wrong models, textures or scripts.",
                    evidence: ["prefix '\(g.prefix)': \(pa.name) (\(name(pr.a))), \(pb.name) (\(name(pr.b)))"],
                    confidence: same ? 0.8 : 0.7, suggestedEnable: [], suggestedDisable: []))
            } }
        }
        return out
    }
}

// MARK: - Diagnostics

extension Tables {
    /// How the base class of one class path resolves, step by step.
    func explain(_ path: String) -> [String] {
        guard let id = paths.find(path, names) else { return ["\(path): not in the library"] }
        var u = univ
        let n = paths.count
        u.baseMemo = [Int32](repeating: -2, count: n)
        u.vanillaMemo = [Int32](repeating: -2, count: n)
        var out: [String] = []
        var x = id
        var steps = 0
        while x > 0 && steps < 12 {
            steps += 1
            let defs = u.definers(x).map { modNames[Int($0)] }
            out.append("\(paths.string(x, names)): game \(["absent", "declared only", "defined"][Int(u.vState[Int(x)])]); defined by \(defs.isEmpty ? "no mod" : defs.prefix(3).joined(separator: ", "))")
            let alt = (u.altBase[x] ?? []).map { names.strings[Int($0)] }
            out.append("    base names: first '\(u.uBase[Int(x)] >= 0 ? names.strings[Int(u.uBase[Int(x)])] : "-")'" + (alt.isEmpty ? "" : " also \(alt)"))
            let bs = basesOf(&u, x, vanillaOnly: false)
            out.append("    resolves to \(bs.map { paths.string($0, names) })")
            x = bs.first ?? -1
        }
        return out
    }

    /// Base-game classes whose base class `lookup` cannot find among the base game's own classes. The game
    /// loads without such errors, so a rule set that explains it leaves this empty.
    func vanillaResolutionFailures() -> (checked: Int, failures: [String]) {
        var u = univ
        let n = paths.count
        u.vanillaMemo = [Int32](repeating: -2, count: n)
        var checked = 0
        var failures: [String] = []
        for p in 1..<n where u.vState[p] == 2 && u.vBase[p] >= 0 {
            checked += 1
            if lookup(&u, scope: paths.container[p], base: u.vBase[p], selfPath: Int32(p), vanillaOnly: true, all: false).isEmpty {
                failures.append("\(paths.string(Int32(p), names)) : \(names.strings[Int(u.vBase[p])])")
            }
        }
        return (checked, failures)
    }
}
