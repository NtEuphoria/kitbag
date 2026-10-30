// Re-reads the claims of findings straight from the PBOs (RapParser / text parser, no index, no cache).
import Foundation

enum Verify {
    /// All class definitions of one mod folder: path → [(pbo, ConfigClass)].
    nonisolated(unsafe) static var parsed: [String: [String: [(String, ConfigClass)]]] = [:]

    static func classes(of modFolder: String) -> [String: [(String, ConfigClass)]] {
        if let p = parsed[modFolder] { return p }
        var out: [String: [(String, ConfigClass)]] = [:]
        for url in loadedPBOs(in: URL(fileURLWithPath: modFolder)) {
            for (_, root) in Inspect.configRoots(pbo: url) {
                func walk(_ c: ConfigClass, _ path: String) {
                    for ch in c.children {
                        let p = path.isEmpty ? ch.name.lowercased() : path + "/" + ch.name.lowercased()
                        if !ch.isExternal { out[p, default: []].append((url.lastPathComponent, ch)) }
                        walk(ch, p)
                    }
                }
                walk(root, "")
            }
        }
        parsed[modFolder] = out
        return out
    }

    static func modID(_ name: String, _ names: [String: String], _ index: GameIndex) -> String? {
        index.modOrder.first { names[$0] == name }
    }

    /// Splits `path.prop: A = va, B = vb` into parts; mod names may contain commas, so match known names.
    static func parseEvidence(_ e: String, mods: [String], names: [String: String]) -> (path: String, prop: String, values: [(String, String)])? {
        guard let colon = e.range(of: ": ") else { return nil }
        let head = String(e[..<colon.lowerBound])
        guard let dot = head.lastIndex(of: ".") else { return nil }
        let path = String(head[..<dot]), prop = String(head[head.index(after: dot)...])
        var rest = String(e[colon.upperBound...])
        var out: [(String, String)] = []
        let known = mods.compactMap { names[$0] }.sorted { $0.count > $1.count }
        while !rest.isEmpty {
            guard let n = known.first(where: { rest.hasPrefix($0 + " = ") }) else { break }
            rest.removeFirst(n.count + 3)
            // value runs to the next ", <known mod> = " or the end
            var end = rest.endIndex
            for k in known { if let r = rest.range(of: ", " + k + " = "), r.lowerBound < end { end = r.lowerBound } }
            out.append((n, String(rest[..<end])))
            rest = end < rest.endIndex ? String(rest[rest.index(end, offsetBy: 2)...]) : ""
        }
        return (path, prop, out)
    }

    static func run() {
        let (index, names) = Lib.load()
        let ctx = ConflictContext(index: index, names: names)
        let f = ctx.analyze(enabled: index.modOrder)
        // 1. property conflict evidence
        var checked = 0, ok = 0
        var bad: [String] = []
        for x in f where x.kind == .propertyConflict {
            for e in x.evidence {
                guard let (path, prop, values) = parseEvidence(e, mods: x.modPaths, names: names), values.count >= 1 else { continue }
                for (n, claimed) in values {
                    guard let m = modID(n, names, index) else { continue }
                    checked += 1
                    let defs = classes(of: m)[path] ?? []
                    let actual = defs.compactMap { $0.1.properties[prop] }
                    let want = claimed.hasSuffix("…") ? String(claimed.dropLast()) : claimed
                    if actual.contains(where: { canon($0.fingerprint).hasPrefix(canon(want)) }) { ok += 1 } else { bad.append("\(n) \(path).\(prop): claimed \(claimed.prefix(60)), actual \(actual.map { $0.fingerprint.prefix(60) })") }
                }
            }
        }
        print("property evidence: \(checked) mod values re-read from the PBOs, \(ok) match, \(bad.count) do not")
        for b in bad.prefix(10) { print("   MISMATCH \(b)") }
        // 2. base class evidence
        var bc = 0, bok = 0
        var bbad: [String] = []
        for x in f where x.kind == .baseClassChange {
            for e in x.evidence {
                // "<path>: A says 'x', B says 'y'" or "<path>: M says 'x'; the game and ..." or "<path>: 'a' → 'b'"
                guard let colon = e.range(of: ": ") else { continue }
                let path = String(e[..<colon.lowerBound])
                var rest = e[colon.upperBound...]
                if rest.hasPrefix("'") { // intended: 'old' → 'new'
                    guard let m = x.modPaths.first, let arrow = rest.range(of: " → '") else { continue }
                    let new = rest[arrow.upperBound...].dropLast().lowercased()
                    bc += 1
                    if (classes(of: m)[path] ?? []).contains(where: { $0.1.parent?.lowercased() == new }) { bok += 1 } else { bbad.append("\(names[m] ?? m) \(path): \(e)") }
                    continue
                }
                // "<mod> says 'x'; the game and A, B and 3 more say 'y'": the game and every named keeper.
                if let g = rest.range(of: "; the game") , let say = rest.range(of: " say '", range: g.upperBound..<rest.endIndex) {
                    let claimed = String(rest[say.upperBound...].dropLast()).lowercased()
                    bc += 1
                    if (index.vanilla.parents[path] ?? "") == (claimed == "(none)" ? "" : claimed) { bok += 1 } else { bbad.append("game \(path): claimed '\(claimed)', actual '\(index.vanilla.parents[path] ?? "absent")'") }
                    var who = String(rest[g.upperBound..<say.lowerBound])
                    if who.hasPrefix(" and ") { who.removeFirst(5) } else { who = "" }
                    for n in who.components(separatedBy: ", ").flatMap({ $0.components(separatedBy: " and ") }) {
                        guard let km = names.first(where: { $0.value == n })?.key else { continue }
                        bc += 1
                        if (classes(of: km)[path] ?? []).contains(where: { ($0.1.parent ?? "(none)").lowercased() == claimed }) { bok += 1 } else { bbad.append("keeper \(n) \(path): claimed '\(claimed)'") }
                    }
                }
                for m in x.modPaths {
                    guard let n = names[m], let r = rest.range(of: n + " says '") else { continue }
                    let after = rest[r.upperBound...]
                    guard let q = after.firstIndex(of: "'") else { continue }
                    let claimed = String(after[..<q]).lowercased()
                    bc += 1
                    if (classes(of: m)[path] ?? []).contains(where: { ($0.1.parent ?? "(none)").lowercased() == claimed }) { bok += 1 } else { bbad.append("\(n) \(path): claimed '\(claimed)'") }
                }
                _ = rest; rest = ""
            }
        }
        print("base class evidence: \(bc) claims re-read from the PBOs, \(bok) match, \(bbad.count) do not")
        for b in bbad.prefix(10) { print("   MISMATCH \(b)") }
        // 3. undefined bases: is the base name defined anywhere in the whole library, at any scope?
        var leafs: [String: [String]] = [:]
        for (p, _) in index.vanilla.parents { leafs[String(p.split(separator: "/").last ?? ""), default: []].append("game:" + p) }
        for m in index.modOrder { for pbo in index.mods[m]!.pbos { for c in pbo.summary.classes where !c.external {
            leafs[String(c.path.split(separator: "/").last ?? ""), default: []].append("\(names[m] ?? m):" + c.path)
        } } }
        var nowhereStrong = 0, nowhereWeak = 0, weak: [String] = []
        for x in f where x.kind == .undefinedBaseClass && x.suggestedEnable.isEmpty {
            for e in x.evidence {
                guard e.hasPrefix("base '"), let q = e.dropFirst(6).firstIndex(of: "'") else { continue }
                let base = String(e.dropFirst(6)[..<q])
                if (leafs[base] ?? []).isEmpty { nowhereStrong += 1 } else { nowhereWeak += 1; weak.append("\(x.title.prefix(50)) base '\(base)' exists elsewhere: \((leafs[base] ?? []).prefix(3))") }
            }
        }
        print("undefined bases with no mod to blame: \(nowhereStrong) base names exist nowhere in the library at any scope; \(nowhereWeak) exist at some other scope")
        for w in weak.prefix(25) { print("   \(w)") }
        // 4. duplicates: are the colliding PBOs byte-identical?
        for x in f where x.kind == .duplicateAddon || x.kind == .prefixCollision {
            guard x.modPaths.count >= 2 else { continue }
            let a = Set(loadedPBOs(in: URL(fileURLWithPath: x.modPaths[0])).map { $0.lastPathComponent.lowercased() })
            var same = 0, differ = 0
            for m in x.modPaths.dropFirst() {
                for u in loadedPBOs(in: URL(fileURLWithPath: m)) where a.contains(u.lastPathComponent.lowercased()) {
                    let other = loadedPBOs(in: URL(fileURLWithPath: x.modPaths[0])).first { $0.lastPathComponent.lowercased() == u.lastPathComponent.lowercased() }!
                    if let d1 = try? Data(contentsOf: u, options: .alwaysMapped), let d2 = try? Data(contentsOf: other, options: .alwaysMapped) { if d1 == d2 { same += 1 } else { differ += 1 } }
                }
            }
            print("dup check [\(x.kind.rawValue)] \(x.title.prefix(90)): same-named PBOs byte-identical \(same), different \(differ); suggestedDisable \(x.suggestedDisable.map { names[$0] ?? $0 })")
        }
    }

    static func canon(_ s: String) -> String { s.replacingOccurrences(of: " ", with: "").lowercased() }
}
