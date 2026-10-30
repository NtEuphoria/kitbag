// Parses every config.bin (any depth) in every loaded PBO of the Workshop mods and the base game,
// plus every other rapified entry (rvmat, bisurf, sqm, …) as extra robustness input.
import Foundation

enum Corpus {
    static let steam = "\(NSHomeDirectory())/Library/Application Support/Steam/steamapps"
    static let workshop = URL(fileURLWithPath: steam + "/workshop/content/107410")
    static let game = URL(fileURLWithPath: steam + "/common/Arma 3")
    static let otherExtensions: Set<String> = ["rvmat", "bisurf", "sqm", "ext", "bin", "cpp", "hpp", "cfg", "inc", "h"]

    enum Origin: String, CaseIterable { case mod, vanilla, dta }
    struct Job { let origin: Origin; let owner: String; let pbo: URL }

    static func jobs() -> [Job] {
        let fm = FileManager.default
        var out: [Job] = []
        let mods = ((try? fm.contentsOfDirectory(atPath: workshop.path)) ?? []).filter { Int($0) != nil }.sorted()
        for id in mods { out += loadedPBOs(in: workshop.appendingPathComponent(id)).map { Job(origin: .mod, owner: id, pbo: $0) } }
        out += loadedPBOs(in: game).map { Job(origin: .vanilla, owner: "Addons", pbo: $0) }
        for sub in ((try? fm.contentsOfDirectory(at: game, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []).sorted(by: { $0.path < $1.path }) {
            let name = sub.lastPathComponent
            if Int(name) != nil || name.hasSuffix(".app") || name.hasPrefix("@") { continue }
            if (try? sub.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { continue }
            if name.lowercased() == "dta" {
                let files = (try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil)) ?? []
                out += files.filter { $0.pathExtension.lowercased() == "pbo" }.map { Job(origin: .dta, owner: name, pbo: $0) }
            } else {
                out += loadedPBOs(in: sub).map { Job(origin: .vanilla, owner: name, pbo: $0) }
            }
        }
        return out
    }

    struct Stats {
        var pbos = 0, pboErrors: [String] = []
        var configBins = 0, nestedConfigBins = 0, configBinBytes = 0, largest = (0, "")
        var notRapified: [String] = [], rapifiedConfigCpp: [String] = [], configCpp = 0
        var failures: [String] = []
        var classes = 0, externals = 0, maxDepth = 0
        var parseSeconds = 0.0
        var addons = 0, skipAddons: [String] = [], requiredVersions: [String: Int] = [:]
        var skipRaw: [String: Int] = [:], versionRaw: [String: Int] = [:], requiredAppends: [String] = []
        var duplicatePatchNames: [String] = []
        var v1Diffs: [String] = [], v1Compared = 0
        var countMismatches: [String] = []
        var census = CensusTotals()
        var otherRapified = 0, otherFailures: [String: [String]] = [:], otherExtensions: [String: Int] = [:]

        mutating func merge(_ o: Stats) {
            pbos += o.pbos; pboErrors += o.pboErrors
            configBins += o.configBins; nestedConfigBins += o.nestedConfigBins; configBinBytes += o.configBinBytes
            if o.largest.0 > largest.0 { largest = o.largest }
            notRapified += o.notRapified; rapifiedConfigCpp += o.rapifiedConfigCpp; configCpp += o.configCpp
            failures += o.failures; classes += o.classes; externals += o.externals; maxDepth = max(maxDepth, o.maxDepth)
            parseSeconds += o.parseSeconds; addons += o.addons; skipAddons += o.skipAddons
            requiredVersions.merge(o.requiredVersions, uniquingKeysWith: +)
            skipRaw.merge(o.skipRaw, uniquingKeysWith: +); versionRaw.merge(o.versionRaw, uniquingKeysWith: +)
            requiredAppends += o.requiredAppends
            duplicatePatchNames += o.duplicatePatchNames
            v1Diffs += o.v1Diffs; v1Compared += o.v1Compared; countMismatches += o.countMismatches
            census.merge(o.census)
            otherRapified += o.otherRapified
            otherFailures.merge(o.otherFailures, uniquingKeysWith: +)
            otherExtensions.merge(o.otherExtensions, uniquingKeysWith: +)
        }
    }

    struct CensusTotals {
        var entryTypes: [Int: Int] = [:], valueTypes: [Int: Int] = [:], elemTypes: [Int: Int] = [:], appendFlags: [UInt32: Int] = [:]
        var maxArrayDepth = 0, deletes = 0, floats = 0, floatMismatches = 0, floatExamples: [String] = []
        var headerOdd: [String] = [], enumNonEmpty = 0, enumBad: [String] = [], bodiesPastEnum: [String] = []
        var nonContiguous = 0, overlap: [String] = [], binarizeLayout = 0, contiguousLayout: [String] = [], otherLayout: [String] = []
        var dupClass: [String] = [], dupProp: [String] = [], externalThenDefined: [String] = [], propAndClass: [String] = []
        var failures: [String] = []

        mutating func add(_ c: Census, _ file: String) {
            entryTypes.merge(c.entryTypes, uniquingKeysWith: +); valueTypes.merge(c.valueTypes, uniquingKeysWith: +)
            elemTypes.merge(c.elemTypes, uniquingKeysWith: +); appendFlags.merge(c.appendFlags, uniquingKeysWith: +)
            maxArrayDepth = max(maxArrayDepth, c.maxArrayDepth); deletes += c.deletes
            floats += c.floats; floatMismatches += c.floatMismatches; floatExamples += c.floatsNotDescription.prefix(3)
            if let h = c.headerOdd { headerOdd.append("\(file) \(h)") }
            if c.enumCount > 0 { enumNonEmpty += 1 }
            if !c.enumOK { enumBad.append("\(file) enumOffset=\(c.enumOffset)") }
            if c.bodiesPastEnum { bodiesPastEnum.append(file) }
            if !c.bodiesContiguous { nonContiguous += 1 }
            if c.binarizeTrailers { binarizeLayout += 1 } else if c.bodiesContiguous { contiguousLayout.append(file) } else { otherLayout.append(file) }
            if c.bodiesOverlap { overlap.append(file) }
            dupClass += c.dupClass.map { "\(file): \($0)" }; dupProp += c.dupProp.map { "\(file): \($0)" }
            externalThenDefined += c.externalThenDefined.map { "\(file): \($0)" }
            propAndClass += c.propAndClass.map { "\(file): \($0)" }
        }

        mutating func merge(_ o: CensusTotals) {
            entryTypes.merge(o.entryTypes, uniquingKeysWith: +); valueTypes.merge(o.valueTypes, uniquingKeysWith: +)
            elemTypes.merge(o.elemTypes, uniquingKeysWith: +); appendFlags.merge(o.appendFlags, uniquingKeysWith: +)
            maxArrayDepth = max(maxArrayDepth, o.maxArrayDepth); deletes += o.deletes
            floats += o.floats; floatMismatches += o.floatMismatches; floatExamples += o.floatExamples
            headerOdd += o.headerOdd; enumNonEmpty += o.enumNonEmpty; enumBad += o.enumBad; bodiesPastEnum += o.bodiesPastEnum
            nonContiguous += o.nonContiguous; overlap += o.overlap
            binarizeLayout += o.binarizeLayout; contiguousLayout += o.contiguousLayout; otherLayout += o.otherLayout
            dupClass += o.dupClass; dupProp += o.dupProp; externalThenDefined += o.externalThenDefined; propAndClass += o.propAndClass
            failures += o.failures
        }
    }

    static func countClasses(_ c: ConfigClass, depth: Int = 0) -> (all: Int, external: Int, depth: Int) {
        var all = 0, ext = 0, d = depth
        for k in c.children {
            all += 1
            if k.isExternal { ext += 1 }
            let sub = countClasses(k, depth: depth + 1)
            all += sub.all; ext += sub.external; d = max(d, sub.depth)
        }
        return (all, ext, d)
    }

    static func scan(_ job: Job) -> Stats {
        var s = Stats()
        s.pbos = 1
        let archive: PBOArchive
        do { archive = try PBOArchive(url: job.pbo) } catch {
            s.pboErrors.append("\(job.owner)/\(job.pbo.lastPathComponent): \(error)"); return s
        }
        for e in archive.entries {
            let base = e.path.split(separator: "\\").last.map(String.init) ?? e.path
            let file = "\(job.owner)/\(job.pbo.lastPathComponent):\(e.path)"
            if base == "config.cpp" {
                s.configCpp += 1
                if let d = archive.contents(of: e), RapParser.isRapified(d) { s.rapifiedConfigCpp.append(file) }
                continue
            }
            if base != "config.bin" {
                let ext = (base as NSString).pathExtension
                guard otherExtensions.contains(ext), let d = archive.contents(of: e), RapParser.isRapified(d) else { continue }
                s.otherRapified += 1
                s.otherExtensions[ext, default: 0] += 1
                do { _ = try RapParser.parse(d) } catch { s.otherFailures[ext, default: []].append("\(file): \(error)") }
                continue
            }
            s.configBins += 1
            if e.path.contains("\\") { s.nestedConfigBins += 1 }
            guard let data = archive.contents(of: e), data.count == e.originalSize || e.packing != PBOArchive.cprsMagic else {
                s.failures.append("\(file): truncated or undecompressable entry"); continue
            }
            s.configBinBytes += data.count
            if data.count > s.largest.0 { s.largest = (data.count, file) }
            guard RapParser.isRapified(data) else { s.notRapified.append(file); continue }

            let t0 = DispatchTime.now().uptimeNanoseconds
            let root: ConfigClass
            do { root = try RapParser.parse(data) } catch {
                s.failures.append("\(file): \(error)")
                if (try? Census.of(data)) == nil { s.census.failures.append(file) }
                continue
            }
            s.parseSeconds += Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9

            let n = countClasses(root)
            s.classes += n.all; s.externals += n.external; s.maxDepth = max(s.maxDepth, n.depth)
            do {
                let c = try Census.of(data)
                s.census.add(c, file)
                if c.classes + c.externals != n.all { s.countMismatches.append("\(file): census \(c.classes + c.externals) vs tree \(n.all)") }
            } catch { s.census.failures.append("\(file): \(error)") }

            for c in root.child("CfgPatches")?.children.filter({ !$0.isExternal }) ?? [] {
                // Raw kinds, to see what PatchInfo.extract's numberValue reads miss.
                func kind(_ v: ConfigValue?) -> String {
                    switch v {
                    case nil: return "absent"
                    case .number(let n)?: return "number \(ConfigValue.number(n).fingerprint)"
                    case .string(let t)?: return "string \"\(t)\""
                    case .array?: return "array"
                    }
                }
                s.skipRaw[kind(c.properties["skipwhenmissingdependencies"]), default: 0] += 1
                let rv = kind(c.properties["requiredversion"])
                s.versionRaw[rv.hasPrefix("number") ? "number" : rv, default: 0] += 1
                if c.appends["requiredaddons"] != nil { s.requiredAppends.append("\(file): \(c.name)") }
            }
            let patches = PatchInfo.extract(from: root)
            var mine: Patches = [:]
            for p in patches {
                s.addons += 1
                if p.skipWhenMissingDependencies { s.skipAddons.append("\(job.owner):\(p.name)") }
                let v = p.requiredVersion.map { ConfigValue.number($0).fingerprint } ?? "none"
                s.requiredVersions[v, default: 0] += 1
                if mine[p.name] != nil { s.duplicatePatchNames.append("\(file): \(p.name)") }
                mine[p.name] = p.skipWhenMissingDependencies ? [] : p.requiredAddons
            }
            let v1 = V1.patches(data)
            s.v1Compared += 1
            if v1 != mine { s.v1Diffs.append(describe(file, v1: v1, mine: mine, root: root)) }
        }
        return s
    }

    static func describe(_ file: String, v1: Patches, mine: Patches, root: ConfigClass) -> String {
        var lines = ["\(file):"]
        for k in Set(v1.keys).subtracting(mine.keys).sorted() { lines.append("  only v1: \(k) = \(v1[k]!)") }
        for k in Set(mine.keys).subtracting(v1.keys).sorted() { lines.append("  only new: \(k) = \(mine[k]!)") }
        for k in Set(mine.keys).intersection(v1.keys).sorted() where mine[k] != v1[k] {
            let cls = root.child("CfgPatches")?.child(k)
            let props = cls.map { c in c.properties.filter { ["requiredaddons", "skipwhenmissingdependencies"].contains($0.key) }
                .map { "\($0.key)=\($0.value.fingerprint)" } + c.appends.map { "\($0.key)+=\(ConfigValue.array($0.value).fingerprint)" } } ?? []
            lines.append("  \(k): v1 \(v1[k]!) | new \(mine[k]!)  [\(props.joined(separator: "; "))]")
        }
        return lines.joined(separator: "\n")
    }

    /// Health v1 scanned every *.pbo under a mod folder; Arma loads only addons/*.pbo. Counts what v1
    /// read that the game never loads, and the CfgPatches addons (with their requirements) it picked up.
    static func v1FileSet() {
        let fm = FileManager.default
        var extra: [String: Int] = [:], addons = 0, withRequirements = 0, mods = Set<String>(), examples: [String] = []
        for id in ((try? fm.contentsOfDirectory(atPath: workshop.path)) ?? []).filter({ Int($0) != nil }).sorted() {
            let folder = workshop.appendingPathComponent(id)
            let loaded = Set(loadedPBOs(in: folder).map(\.standardizedFileURL.path))
            guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: nil) else { continue }
            for case let u as URL in e where u.pathExtension.lowercased() == "pbo" && !loaded.contains(u.standardizedFileURL.path) {
                let rel = String(u.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count + 1))
                extra[rel.split(separator: "/").first.map { String($0).lowercased() } ?? "?", default: 0] += 1
                mods.insert(id)
                guard let a = try? PBOArchive(url: u) else { continue }
                for entry in a.entries where entry.path.hasSuffix("config.bin") {
                    guard let d = a.contents(of: entry), let root = try? RapParser.parse(d) else { continue }
                    for p in PatchInfo.extract(from: root) {
                        addons += 1
                        if !p.skipWhenMissingDependencies && !p.requiredAddons.isEmpty {
                            withRequirements += 1
                            if examples.count < 8 { examples.append("\(id)/\(rel): \(p.name) needs \(p.requiredAddons.prefix(4))") }
                        }
                    }
                }
            }
        }
        print("\n== v1 file set (recursive *.pbo) vs loaded addons/*.pbo ==")
        print("PBOs v1 read that Arma doesn't load: \(extra.values.reduce(0, +)) in \(mods.count) mods, by top folder \(extra.sorted { $0.value > $1.value })")
        print("their CfgPatches addons (config.bin only): \(addons), with hard requirements \(withRequirements)")
        for x in examples { print("  " + x) }
    }

    static func run(serial: Bool) {
        let start = Date()
        let all = jobs()
        print("PBOs to scan: \(all.count) (mods \(all.filter { $0.origin == .mod }.count), vanilla \(all.filter { $0.origin == .vanilla }.count), dta \(all.filter { $0.origin == .dta }.count)); mod folders \(Set(all.filter { $0.origin == .mod }.map(\.owner)).count)")
        var results: [Origin: Stats] = [:]
        let lock = NSLock()
        let work = { (k: Int) in
            let s = autoreleasepool { scan(all[k]) }
            lock.lock(); results[all[k].origin, default: Stats()].merge(s); lock.unlock()
        }
        if serial { for k in all.indices { work(k) } } else { DispatchQueue.concurrentPerform(iterations: all.count, execute: work) }
        let wall = Date().timeIntervalSince(start)
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)

        var total = Stats()
        for o in Origin.allCases {
            guard let s = results[o] else { continue }
            total.merge(s)
            print("\n== \(o.rawValue) ==")
            print("PBOs \(s.pbos) (open errors \(s.pboErrors.count)); config.bin \(s.configBins) (nested \(s.nestedConfigBins), at root \(s.configBins - s.nestedConfigBins)), \(s.configBinBytes / 1_048_576) MB, largest \(s.largest.0 / 1024) KB \(s.largest.1)")
            print("parse failures \(s.failures.count); not rapified \(s.notRapified.count); config.cpp \(s.configCpp) of which rapified \(s.rapifiedConfigCpp.count)")
            print("classes \(s.classes) (external \(s.externals)), max class depth \(s.maxDepth), parse CPU \(String(format: "%.2f", s.parseSeconds)) s")
            print("addons (CfgPatches) \(s.addons); skipWhenMissingDependencies=1: \(s.skipAddons.count) in \(Set(s.skipAddons.map { $0.prefix { $0 != ":" } }).count) mods; duplicate addon names within one file \(s.duplicatePatchNames.count)")
            print("requiredVersion: " + s.requiredVersions.sorted { $0.value > $1.value }.map { "\($0.key)×\($0.value)" }.joined(separator: ", "))
            print("skipWhenMissingDependencies raw: " + s.skipRaw.sorted { $0.value > $1.value }.map { "\($0.key)×\($0.value)" }.joined(separator: ", "))
            print("requiredVersion raw kinds: \(s.versionRaw); requiredAddons[] += in CfgPatches: \(s.requiredAppends.count)")
            print("v1 compared \(s.v1Compared), differing files \(s.v1Diffs.count)")
            print("other rapified entries \(s.otherRapified) \(s.otherExtensions), failures \(s.otherFailures.mapValues(\.count))")
        }
        let c = total.census
        print("\n== totals ==")
        print("config.bin \(total.configBins), failures \(total.failures.count), classes \(total.classes), wall \(String(format: "%.1f", wall)) s (\(serial ? "serial" : "parallel")), parse CPU \(String(format: "%.2f", total.parseSeconds)) s, peak RSS \(usage.ru_maxrss / 1_048_576) MB")
        print("census: entry types \(c.entryTypes.sorted { $0.key < $1.key }), value subtypes \(c.valueTypes.sorted { $0.key < $1.key }), array element types \(c.elemTypes.sorted { $0.key < $1.key }), += flags \(c.appendFlags), deletes \(c.deletes)")
        print("census: max array depth \(c.maxArrayDepth), floats \(c.floats), widen≠description \(c.floatMismatches) \(c.floatExamples.prefix(10))")
        print("census: odd header \(c.headerOdd.count), enum table non-empty \(c.enumNonEmpty), enum table not at offset/EOF \(c.enumBad.count), bodies past enum \(c.bodiesPastEnum.count), non-contiguous bodies \(c.nonContiguous), overlapping \(c.overlap.count), census failures \(c.failures.count)")
        print("census: layout Binarize (u32 subtree-end trailer after every body) \(c.binarizeLayout), contiguous without trailers \(c.contiguousLayout.count), other \(c.otherLayout.count)")
        print("census: duplicate classes \(c.dupClass.count), duplicate properties \(c.dupProp.count), external-then-defined \(c.externalThenDefined.count), same name as class+property \(c.propAndClass.count)")
        print("tree/census class count mismatches \(total.countMismatches.count)")
        func dump(_ title: String, _ list: [String], _ n: Int = 40) {
            guard !list.isEmpty else { return }
            print("\n-- \(title) (\(list.count)) --")
            for l in list.sorted().prefix(n) { print(l) }
        }
        dump("PBO open errors", total.pboErrors)
        dump("PARSE FAILURES", total.failures, 200)
        dump("config.bin not rapified", total.notRapified)
        dump("rapified config.cpp", total.rapifiedConfigCpp)
        let otherFails = total.otherFailures.values.flatMap { $0 }
        let asciiFails = otherFails.filter { f in f.split(separator: ":").dropFirst().first.map { $0.unicodeScalars.allSatisfy(\.isASCII) } ?? true }
        print("\nother rapified failures \(otherFails.count): non-ASCII (decoy) names \(otherFails.count - asciiFails.count), ASCII names \(asciiFails.count), in mods \(Set(otherFails.map { $0.prefix { $0 != "/" } }).sorted())")
        let decoys = Dictionary(grouping: otherFails.filter { !asciiFails.contains($0) }) { f in String(f.prefix { $0 != ":" }) }
        print("non-ASCII-name failures by PBO: " + decoys.map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: ", "))
        dump("other rapified failures with ASCII names", asciiFails, 60)
        dump("v1 differences", total.v1Diffs, 200)
        dump("skipWhenMissingDependencies addons", total.skipAddons, 100)
        dump("duplicate addon names in one file", total.duplicatePatchNames)
        dump("census: odd header", c.headerOdd)
        dump("census: enum table problems", c.enumBad, 20)
        dump("census: bodies past enum", c.bodiesPastEnum)
        dump("census: overlap", c.overlap)
        dump("census: contiguous layout (no trailers)", c.contiguousLayout)
        dump("census: other layout", c.otherLayout)
        dump("census: duplicate classes", c.dupClass, 30)
        dump("census: external then defined", c.externalThenDefined, 30)
        dump("census: duplicate properties", c.dupProp, 30)
        dump("census: class+property same name", c.propAndClass, 30)
        dump("census failures", c.failures)
        dump("class count mismatches", total.countMismatches)
        dump("requiredAddons[] += in CfgPatches", total.requiredAppends)
        v1FileSet()
    }
}
