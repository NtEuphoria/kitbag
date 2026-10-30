// Compares the analysis with the Workshop's own statements (Tests/groundtruth/workshop.json: requiredItems, requiredDLC).
import Foundation

enum Truth {
    struct Entry { var title: String; var required: [String]; var dlc: [String] }

    static func load() -> [String: Entry] {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/Tests/groundtruth/workshop.json")
        guard let data = try? Data(contentsOf: url), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [String: Entry] = [:]
        for (id, v) in root {
            guard let d = v as? [String: Any] else { continue }
            let req = ((d["requiredItems"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
            out[id] = Entry(title: (d["title"] as? String) ?? id, required: req, dlc: (d["requiredDLC"] as? [String]) ?? [])
        }
        return out
    }

    static func id(_ path: String) -> String { URL(fileURLWithPath: path).lastPathComponent }

    /// Each mod enabled alone: what we say it needs vs what its Workshop page declares.
    static func dependencies() {
        let (index, names) = Lib.load()
        let ctx = ConflictContext(index: index, names: names)
        let truth = load()
        let installed = Set(index.modOrder.map(id))
        var flagged = 0, agree = 0, undeclared: [String] = [], dlcAgree = 0, dlcMiss: [String] = [], dlcNamed = 0
        var quiet = 0
        for m in index.modOrder {
            let f = ctx.analyze(enabled: [m]).filter { $0.kind == .missingDependency && $0.modPaths.first == m }
            let t = truth[id(m)]
            if f.isEmpty { quiet += 1; continue }
            flagged += 1
            let suggested = Set(f.flatMap(\.suggestedEnable).map(id))
            // closure of declared requirements among installed items
            var closure = Set<String>(); var stack = t?.required ?? []
            while let x = stack.popLast() { if closure.insert(x).inserted { stack += truth[x]?.required ?? [] } }
            let extra = suggested.subtracting(closure)
            if extra.isEmpty { agree += 1 } else {
                undeclared.append("\(names[m] ?? m): we say needs \(extra.map { (truth[$0]?.title ?? $0) }) ; Workshop declares \((t?.required ?? []).map { truth[$0]?.title ?? $0 })")
            }
            let wantsDLC = f.contains { $0.title.contains("Creator DLC") || $0.evidence.contains { $0.contains("Creator DLC") } }
            if wantsDLC { dlcNamed += 1; if !(t?.dlc ?? []).isEmpty { dlcAgree += 1 } else { dlcMiss.append(names[m] ?? m) } }
        }
        // Declared dependencies that are installed but that we never need (informational).
        var declaredInstalled = 0, weNeed = 0
        for m in index.modOrder {
            guard let t = truth[id(m)] else { continue }
            for r in t.required where installed.contains(r) {
                declaredInstalled += 1
                let f = ctx.analyze(enabled: index.modOrder.filter { id($0) != r })
                if f.contains(where: { $0.kind == .missingDependency && $0.modPaths.first == m && $0.suggestedEnable.map(id).contains(r) }) { weNeed += 1 }
            }
        }
        print("each mod alone: \(flagged) flagged, \(quiet) quiet. Flagged whose suggested providers are all declared (transitively) on the Workshop: \(agree); with providers the Workshop does not declare: \(undeclared.count)")
        for u in undeclared.prefix(30) { print("  UNDECLARED \(u)") }
        print("Creator DLC named for \(dlcNamed) mods; Workshop lists requiredDLC for \(dlcAgree); not listed: \(dlcMiss)")
        print("declared required items that are installed: \(declaredInstalled); of those, mods where disabling the item makes us report it as needed: \(weNeed)")
    }
}
