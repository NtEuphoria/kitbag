import Foundation

enum Stats {
    static func summarize(_ f: [ConflictFinding]) -> String {
        var d: [String: Int] = [:]
        for x in f { d["\(x.kind.rawValue)/\(x.severity)", default: 0] += 1 }
        return d.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }

    static func run() {
        let (index, names) = Lib.load()
        let rss0 = rssMB()
        let t0 = Date()
        let ctx = ConflictContext(index: index, names: names)
        print(String(format: "context init %.2f s; RSS %d MB -> %d MB (index alive)", Date().timeIntervalSince(t0), rss0, rssMB()))
        for (k, v) in ctx.statistics.sorted(by: { $0.key < $1.key }) { print("  \(k): \(v)") }
        let all = index.modOrder
        var best = 1e9
        var f: [ConflictFinding] = []
        for _ in 0..<5 { let t = Date(); f = ctx.analyze(enabled: all); best = min(best, Date().timeIntervalSince(t)) }
        print(String(format: "analyze(all %d): best of 5 %.1f ms; %d findings: %@", all.count, best * 1000, f.count, summarize(f)))
        let kind = ProcessInfo.processInfo.environment["KIND"]
        let sev = ProcessInfo.processInfo.environment["SEV"]
        let limit = Int(ProcessInfo.processInfo.environment["N"] ?? "15") ?? 15
        var shown = 0
        for x in f where (kind == nil || x.kind.rawValue == kind) && (sev == nil || "\(x.severity)" == sev) {
            if shown >= limit { break }
            shown += 1
            print("\n[\(x.kind.rawValue)/\(x.severity) conf \(x.confidence)] \(x.title)\n  \(x.detail)")
            for e in x.evidence { print("    - \(e)") }
            if !x.suggestedEnable.isEmpty { print("  enable: \(x.suggestedEnable.map { names[$0] ?? $0 })") }
            if !x.suggestedDisable.isEmpty { print("  disable: \(x.suggestedDisable.map { names[$0] ?? $0 })") }
        }
    }

    static func vanilla() {
        let (index, names) = Lib.load()
        for _ in 0..<1 {
            let ctx = ConflictContext(index: index, names: names)
            let r = ctx.vanillaResolutionFailures()
            print("checked \(r.checked), unresolved \(r.failures.count), unresolvable demands in mods \(ctx.statistics["unresolvableDemands"] ?? -1), cross \(ctx.statistics["crossDemands"] ?? -1)")
            for f in r.failures.prefix(40) { print("    \(f)") }
        }
    }
}

extension Stats {
    static func probe(_ paths: [String]) {
        let (index, _) = Lib.load()
        let v = index.vanilla
        for p in paths {
            print("\(p): parent=\(v.parents[p].map { "'\($0)'" } ?? "ABSENT") external-only=\(v.externalOnly.contains(p))")
        }
        if let first = paths.first {
            let pre = first.split(separator: "/").dropLast().joined(separator: "/")
            let kids = v.parents.keys.filter { $0.hasPrefix(pre + "/") && $0.split(separator: "/").count == pre.split(separator: "/").count + 1 }.sorted()
            print("children of \(pre): \(kids.prefix(30))")
        }
    }
}

extension Stats {
    /// `find <suffix-or-substring> [limit]` — every definition of matching class paths, by mod.
    static func find(_ args: [String]) {
        let (index, names) = Lib.load()
        let needle = args[0].lowercased()
        let limit = args.count > 1 ? Int(args[1]) ?? 40 : 40
        var rows: [String] = []
        for (p, b) in index.vanilla.parents where p.hasSuffix(needle) || (needle.contains("*") ? false : p == needle) {
            rows.append("\(p)  [game\(index.vanilla.externalOnly.contains(p) ? " external-only" : "")] base '\(b)'")
        }
        for m in index.modOrder { for pbo in index.mods[m]!.pbos { for c in pbo.summary.classes where c.path.hasSuffix(needle) {
            rows.append("\(c.path)  [\(names[m] ?? m) / \(pbo.name)]\(c.external ? " external" : "") base '\(c.parent ?? "")' props \(c.props.count)")
        } } }
        for r in rows.sorted().prefix(limit) { print(r) }
        print("(\(rows.count) matches)")
    }
}

extension Stats {
    static func explain(_ paths: [String]) {
        let (index, names) = Lib.load()
        let ctx = ConflictContext(index: index, names: names)
        for p in paths { print("== \(p)"); for l in ctx.explain(p) { print(l) } }
    }
}

extension Stats {
    static func histogram() {
        let (index, names) = Lib.load()
        let ctx = ConflictContext(index: index, names: names)
        let f = ctx.analyze(enabled: index.modOrder).filter { $0.kind == .propertyConflict }
        var buckets: [String: Int] = [:]
        var props: [String: Int] = [:]
        for x in f {
            let n = Int(x.title.split(separator: " ").first(where: { Int($0) != nil }) ?? "0") ?? 0
            let b = n == 1 ? "1" : n < 5 ? "2-4" : n < 10 ? "5-9" : n < 25 ? "10-24" : n < 100 ? "25-99" : "100+"
            buckets[b, default: 0] += 1
        }
        print(buckets.sorted { $0.key < $1.key })
        // property-name distribution over evidence lines
        for x in f { for e in x.evidence { if let r = e.range(of: ": ") { let head = String(e[..<r.lowerBound]); let prop = head.split(separator: ".").last.map(String.init) ?? head; props[prop, default: 0] += 1 } } }
        print(props.sorted { $0.value > $1.value }.prefix(40))
    }
}

extension Stats {
    static func probes() {
        let (index, names) = Lib.load()
        for m in index.modOrder { for p in index.mods[m]!.pbos where p.usesHasInclude {
            print("\(names[m] ?? m) / \(p.name) prefix '\(p.prefix)': patches \(p.summary.patches.map(\.name))")
            for (k, v) in p.hasIncludeProbes.sorted(by: { $0.key < $1.key }) { print("    \(v ? "yes" : "no ") \(k)") }
        } }
    }
}

extension Stats {
    /// `alone <workshop id or name fragment> ...` — analyze a playset of just those mods.
    static func alone(_ frags: [String]) {
        let (index, names) = Lib.load()
        let ctx = ConflictContext(index: index, names: names)
        var sel: [String] = []
        for f in frags { sel += index.modOrder.filter { URL(fileURLWithPath: $0).lastPathComponent == f || (names[$0] ?? "").lowercased().contains(f.lowercased()) } }
        print("playset: \(sel.map { names[$0] ?? $0 })")
        for x in ctx.analyze(enabled: sel) {
            print("\n[\(x.kind.rawValue)/\(x.severity) conf \(x.confidence)] \(x.title)\n  \(x.detail)")
            for e in x.evidence { print("    - \(e)") }
            if !x.suggestedEnable.isEmpty { print("  enable: \(x.suggestedEnable.map { names[$0] ?? $0 })") }
            if !x.suggestedDisable.isEmpty { print("  disable: \(x.suggestedDisable.map { names[$0] ?? $0 })") }
        }
    }
}

extension Stats {
    static func addons(_ frags: [String]) {
        let (index, names) = Lib.load()
        let v = index.vanilla
        var byFolder: [String: Int] = [:]
        for (_, s) in v.addonSource { byFolder[s.contains("/") ? String(s.split(separator: "/")[0]) : "(Addons)", default: 0] += 1 }
        print("game addons by folder: \(byFolder.sorted { $0.key < $1.key })")
        for f in frags {
            let needle = f.lowercased()
            for a in v.addons.sorted() where a.contains(needle) { print("game: \(a) <- \(v.addonSource[a] ?? "?")") }
            for m in index.modOrder { for p in index.mods[m]!.patches where p.name.contains(needle) { print("\(names[m] ?? m): \(p.name) requires \(p.requiredAddons.prefix(6))\(p.skipWhenMissingDependencies ? " (skip)" : "")") } }
        }
        // mods requiring game addons from DLC-ish folders
        var need: [String: Set<String>] = [:]
        for m in index.modOrder { for p in index.mods[m]!.patches where !p.skipWhenMissingDependencies { for r in p.requiredAddons { if let s = v.addonSource[r], s.contains("/") { need[String(s.split(separator: "/")[0]), default: []].insert(names[m] ?? m) } } } }
        for (k, ms) in need.sorted(by: { $0.key < $1.key }) { print("hard-required by mods from \(k): \(ms.count) mods, e.g. \(ms.sorted().prefix(4))") }
    }
}

extension Stats {
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

    /// Context built from a fresh index that is then dropped: what the context itself keeps alive.
    static func memory() {
        var ctx: ConflictContext?
        do {
            let (index, names) = Lib.load()
            let before = rssMB()
            ctx = ConflictContext(index: index, names: names)
            print("index alive: RSS \(before) MB -> \(rssMB()) MB after building the context")
        }
        Thread.sleep(forTimeInterval: 0.3)
        malloc_zone_pressure_relief(nil, 0)
        print("index dropped, context alive: RSS \(rssMB()) MB; \(ctx!.statistics["propCandidates"] ?? 0) property candidates")
    }
}
