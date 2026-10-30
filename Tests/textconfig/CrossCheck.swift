// Independent check of the text pipeline: when a PBO ships a config.cpp next to the config.bin that was built from
// it, the rapified tree (RapParser) and the preprocessed + parsed text tree should agree class for class.
import Foundation

enum CrossCheck {
    static let verbose = ProcessInfo.processInfo.environment["CROSSCHECK_VERBOSE"] != nil
    struct Diff { let kind: String; let file: String; let detail: String }

    static func report(_ results: [Corpus.Result], names: [String: String]) {
        let pairs = results.filter { $0.tree != nil && $0.bin != nil }
        let binFailures = results.filter { $0.binError != nil }
        print("\ncross-check against config.bin: \(pairs.count) config.cpp/config.bin pairs (\(binFailures.count) bins unreadable)")
        for r in binFailures { print("  bin error \(r.path): \(r.binError!)") }

        var diffs: [Diff] = []
        var identical = 0
        for r in pairs {
            let a = ConfigSummary.make(from: r.tree!, includeProperties: true)
            let b = ConfigSummary.make(from: r.bin!, includeProperties: true)
            let before = diffs.count
            diffs += compare(a, b, file: r.path)
            if diffs.count == before { identical += 1 }
        }
        print("  identical class trees: \(identical) of \(pairs.count)")
        // Differences that come from the build tool rather than from text handling.
        func expected(_ d: Diff) -> String? {
            if d.kind == "class only in bin" && d.detail == "cfgmods" { return "CfgMods class added by the pack tool" }
            if d.kind == "value differs", d.detail.range(of: #"(,"db[+-]?\d|,db[+-]?\d)"#, options: .regularExpression) != nil { return "sound volume 'dbN' converted to a number by some binarizers" }
            if d.kind == "value differs (__EVAL)" { return "__EVAL evaluated by the binarizer" }
            if d.detail.contains(".timepacked") { return "pack timestamp" }
            if d.kind == "class only in text" && d.detail == "bis_addoninfo" { return "BIS_AddonInfo class stripped by the pack tool" }
            if d.kind == "value differs", let r = d.detail.range(of: ": text "), d.detail[r.upperBound...].unicodeScalars.contains(where: { $0.value > 0x7F }) {
                return "non-ASCII display string re-encoded by the pack tool (bin side is mojibake)"
            }
            return nil
        }
        var explained: [String: [Diff]] = [:]
        diffs = diffs.filter { d in if let e = expected(d) { explained[e, default: []].append(d); return false }; return true }
        for (e, list) in explained.sorted(by: { $0.key < $1.key }) {
            print("  expected: \(list.count) x \(e)")
            if verbose { for d in list.prefix(3) { print("      e.g. \(d.file): \(d.detail)") } }
        }
        let differing = Set(diffs.map(\.file))
        print("  files identical once tool differences are set aside: \(pairs.count - differing.count) of \(pairs.count); differing: \(differing.sorted().joined(separator: ", "))")
        let byKind = Dictionary(grouping: diffs, by: \.kind)
        for (kind, list) in byKind.sorted(by: { $0.value.count > $1.value.count }) {
            print("  \(kind): \(list.count) in \(Set(list.map(\.file)).count) files")
            var seen = Set<String>()
            for d in list where seen.insert(d.file).inserted && seen.count <= (verbose ? 1000 : 6) { print("    \(d.file): \(d.detail)") }
        }
    }

    static func compare(_ a: ConfigSummary, _ b: ConfigSummary, file: String) -> [Diff] {
        var out: [Diff] = []
        func add(_ k: String, _ d: String) { out.append(Diff(kind: k, file: file, detail: d)) }

        let pa = Dictionary(a.patches.map { ($0.name, $0) }, uniquingKeysWith: { x, _ in x })
        let pb = Dictionary(b.patches.map { ($0.name, $0) }, uniquingKeysWith: { x, _ in x })
        for n in Set(pa.keys).subtracting(pb.keys).sorted() { add("CfgPatches: only in text", n) }
        for n in Set(pb.keys).subtracting(pa.keys).sorted() { add("CfgPatches: only in bin", n) }
        for (n, x) in pa {
            guard let y = pb[n] else { continue }
            if Set(x.requiredAddons) != Set(y.requiredAddons) {
                add("CfgPatches: requiredAddons differ", "\(n): text-only \(Set(x.requiredAddons).subtracting(y.requiredAddons).sorted()) bin-only \(Set(y.requiredAddons).subtracting(x.requiredAddons).sorted())")
            }
            if x.requiredAddons != y.requiredAddons && Set(x.requiredAddons) == Set(y.requiredAddons) { add("CfgPatches: requiredAddons order", n) }
            if x.requiredVersion != y.requiredVersion { add("CfgPatches: requiredVersion differs", "\(n): \(String(describing: x.requiredVersion)) vs \(String(describing: y.requiredVersion))") }
            if x.skipWhenMissingDependencies != y.skipWhenMissingDependencies { add("CfgPatches: skipWhenMissingDependencies differs", n) }
        }

        // Duplicate paths can occur in either tree (the same class declared twice in a scope); first wins on both sides.
        let ca = Dictionary(a.classes.map { ($0.path, $0) }, uniquingKeysWith: { x, _ in x })
        let cb = Dictionary(b.classes.map { ($0.path, $0) }, uniquingKeysWith: { x, _ in x })
        for p in Set(ca.keys).subtracting(cb.keys).sorted().prefix(200) { add("class only in text", p) }
        for p in Set(cb.keys).subtracting(ca.keys).sorted().prefix(200) { add("class only in bin", p) }
        for (p, x) in ca {
            guard let y = cb[p] else { continue }
            if (x.parent ?? "") != (y.parent ?? "") { add("class parent differs", "\(p): text '\(x.parent ?? "")' bin '\(y.parent ?? "")'") }
            if x.external != y.external { add("class external flag differs", "\(p): text \(x.external) bin \(y.external)") }
            if Set(x.deletes) != Set(y.deletes) { add("class deletes differ", "\(p): text \(x.deletes) bin \(y.deletes)") }
            for k in Set(x.props.keys).subtracting(y.props.keys).sorted() { add("property only in text", "\(p).\(k) = \(x.props[k]!.prefix(80))") }
            for k in Set(y.props.keys).subtracting(x.props.keys).sorted() { add("property only in bin", "\(p).\(k) = \(y.props[k]!.prefix(80))") }
            for (k, v) in x.props {
                guard let w = y.props[k], v != w, !sameNumbers(v, w) else { continue }
                let kind = v.contains("__eval") || w.contains("__eval") ? "value differs (__EVAL)" : "value differs"
                add(kind, "\(p).\(k): text \(v.prefix(160)) bin \(w.prefix(160))")
            }
        }
        return out
    }

    /// Fingerprints that differ only by float32 rounding (about 1 ulp, e.g. dB conversions).
    static func sameNumbers(_ a: String, _ b: String) -> Bool {
        let na = a.split(whereSeparator: { "{},".contains($0) }), nb = b.split(whereSeparator: { "{},".contains($0) })
        guard (a.first == "{") == (b.first == "{"), na.count == nb.count else { return false }
        for (x, y) in zip(na, nb) {
            if x == y { continue }
            guard let dx = Double(x), let dy = Double(y), abs(dx - dy) <= 2e-7 * max(abs(dx), abs(dy)) else { return false }
        }
        return true
    }
}
