// Kitbag health checks: turns the evidence gathered about the installed mods (merged configs,
// Steam's Workshop records, signatures, cited known issues, the last game log) into issues
// for the active playset. Config facts are authoritative; Workshop-only signals stay soft.
import AppKit
import Foundation

// MARK: - Index

/// Everything the health check knows about the library that doesn't depend on which mods are on.
/// Built in the background after each rescan; analysing a playset then takes a few milliseconds.
struct HealthIndex {
    let conflicts: ConflictContext
    /// Mod path → the CfgPatches addons it provides (for the known-issue rules).
    let addons: [String: Set<String>]
    /// Mods with nothing Arma can load: no addons, no Eden composition, not a legacy item.
    let emptyMods: Set<String>
    let signatures: [String: SignatureReport]
    /// Steam's install records, keyed by Workshop ID, across every Steam library.
    let workshop: [String: WorkshopLocalState.Item]
    /// Workshop ID → online details (removed items, Required items). Filled in later; may stay empty.
    var online: [String: WorkshopItemInfo] = [:]
    /// The last game session's log, when Kitbag archived one after the game exited.
    var lastSession: GameLogReport?

    static func build(mods: [Mod], gameFolder: URL?) -> HealthIndex {
        let folders = mods.map { URL(fileURLWithPath: $0.path) }
        let game = ConfigIndexer().build(modFolders: folders, gameFolder: gameFolder)
        let names = Dictionary(mods.map { ($0.path, $0.name) }, uniquingKeysWith: { a, _ in a })

        var workshop: [String: WorkshopLocalState.Item] = [:]
        for lib in Scanner.steamLibraries() {
            let state = WorkshopLocalState.load(steamapps: lib.appendingPathComponent("steamapps"))
            workshop.merge(state.items) { a, _ in a }
        }

        var addons: [String: Set<String>] = [:]
        var empty = Set<String>()
        for m in mods {
            guard let s = game.mods[m.path] else { continue }
            addons[m.path] = Set(s.patches.map(\.name))
            let legacy = m.workshopID.flatMap { workshop[$0]?.isLegacy } ?? false
            if s.pbos.isEmpty && !legacy && !hasEdenContent(m.path) { empty.insert(m.path) }
        }

        var sigs = [SignatureReport?](repeating: nil, count: mods.count)
        sigs.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: mods.count) { i in buf[i] = Signatures.check(modFolder: folders[i]) }
        }
        var signatures: [String: SignatureReport] = [:]
        for (m, r) in zip(mods, sigs) { signatures[m.path] = r }

        return HealthIndex(conflicts: ConflictContext(index: game, names: names), addons: addons,
                           emptyMods: empty, signatures: signatures, workshop: workshop)
    }

    /// Workshop items can be Eden compositions or missions rather than addons.
    private static func hasEdenContent(_ path: String) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return files.contains { let f = $0.lowercased(); return f.hasSuffix(".sqe") || f.hasSuffix(".sqm") || f.hasSuffix(".bin") }
    }
}

// MARK: - Issues

struct Issue: Identifiable {
    enum Severity: Int, Comparable {
        case info, warning, error
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }
    enum Fix { case enable([String]), disable([String]) }
    enum Category: String, CaseIterable {
        case session = "Last Session"
        case dependencies = "Dependencies"
        case conflicts = "Conflicts"
        case workshop = "Workshop & Downloads"
        case knownIssues = "Known Issues"
        case multiplayer = "Multiplayer"
        case playset = "Playset"
    }

    let severity: Severity
    let category: Category
    let title: String
    let detail: String
    var mods: [String] = []      // paths this issue is about (for row badges)
    var fix: Fix?
    var fixLabel = ""
    /// Concrete facts behind the issue (config classes, log lines…), most telling first.
    var evidence: [String] = []
    /// 0…1 when the analysis can tell how sure it is; nil for plain facts (Steam records, logs).
    var confidence: Double?
    var link: URL?
    var linkLabel = ""

    var id: String { category.rawValue + "|" + title + "|" + mods.joined(separator: "|") }
}

enum Health {
    static func analyze(enabled: [Mod], all: [Mod], index: HealthIndex) -> [Issue] {
        let names = Dictionary(all.map { ($0.path, $0.name) }, uniquingKeysWith: { a, _ in a })
        let ids = Dictionary(all.compactMap { m in m.workshopID.map { (m.path, $0) } }, uniquingKeysWith: { a, _ in a })
        let installedIDs = Set(ids.values)
        func name(_ path: String) -> String { names[path] ?? URL(fileURLWithPath: path).lastPathComponent }
        func list(_ paths: [String]) -> String {
            paths.count <= 2 ? paths.map(name).joined(separator: " and ") : "\(paths.count) mods"
        }

        var issues: [Issue] = []

        // Merged-config analysis: the authoritative source for dependencies and conflicts.
        var configMissing: [String: Int] = [:]   // mod path → index of its missing-dependency issue
        var duplicates: [Issue] = []             // dropped later when a cited known issue covers the same mods
        for f in index.conflicts.analyze(enabled: enabled.map(\.path)) {
            var severity = Issue.Severity(rawValue: f.severity.rawValue) ?? .info
            // Base-class changes and value overrides are real but rarely break anything: keep them visible, not alarming.
            if f.kind == .baseClassChange || f.kind == .propertyConflict { severity = .info }
            var issue = Issue(severity: severity,
                              category: [.missingDependency, .undefinedBaseClass].contains(f.kind) ? .dependencies : .conflicts,
                              title: f.title, detail: f.detail, mods: f.modPaths,
                              evidence: f.evidence, confidence: f.confidence)
            if !f.suggestedEnable.isEmpty {
                issue.fix = .enable(f.suggestedEnable)
                issue.fixLabel = "Enable \(list(f.suggestedEnable))"
            } else if !f.suggestedDisable.isEmpty {
                issue.fix = .disable(f.suggestedDisable)
                issue.fixLabel = "Disable \(list(f.suggestedDisable))"
            }
            if f.kind == .missingDependency, let m = f.modPaths.first { configMissing[m] = issues.count }
            if f.kind == .duplicateAddon { duplicates.append(issue) }
            issues.append(issue)
        }

        // Workshop "Required items" that aren't installed. Where the config already proves a missing
        // dependency, attach a subscribe link to that issue; otherwise it's a soft signal (often optional add-ons).
        for m in enabled {
            guard let id = m.workshopID, let reqs = index.online[id]?.requiredItems else { continue }
            let absent = reqs.filter { !installedIDs.contains($0.id) }
            guard let first = absent.first else { continue }
            let link = URL(string: "steam://url/CommunityFilePage/\(first.id)")
            let titles = absent.map(\.title).joined(separator: ", ")
            if let i = configMissing[m.path] {
                issues[i].evidence.insert("Workshop page lists as required: \(titles)", at: 0)
                issues[i].link = link
                issues[i].linkLabel = absent.count == 1 ? "Get \(first.title)" : "Get \(first.title) +\(absent.count - 1)"
            } else {
                issues.append(Issue(severity: .info, category: .workshop,
                                    title: "\(m.name) lists Workshop items you don't have",
                                    detail: "Its config doesn't require them, so they're probably optional add-ons, but the author marks them as required: \(titles).",
                                    mods: [m.path], link: link, linkLabel: "Open in Steam"))
            }
        }

        // Steam's own records for the enabled mods.
        for m in enabled {
            guard let id = m.workshopID else { continue }
            if let item = index.workshop[id] {
                if item.downloading || item.awaitingDownload {
                    issues.append(Issue(severity: .warning, category: .workshop, title: "\(m.name) is still downloading",
                                        detail: "Steam hasn't finished installing it. Wait for the download to finish before you play.",
                                        mods: [m.path]))
                } else if item.needsUpdate {
                    issues.append(Issue(severity: .warning, category: .workshop, title: "\(m.name) has an update waiting",
                                        detail: "Steam only installs Workshop updates while Arma 3 is closed. Let it finish first, or you'll play on the old version (and may not match servers).",
                                        mods: [m.path]))
                } else if item.incomplete, case .missing(let bytes) = item.sizeCheck {
                    issues.append(Issue(severity: .warning, category: .workshop, title: "\(m.name) is incompletely downloaded",
                                        detail: "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) of its files are missing. In Steam, unsubscribe and resubscribe, or verify Arma 3's files.",
                                        mods: [m.path]))
                }
                if item.orphan || item.unsubscribed {
                    issues.append(Issue(severity: .info, category: .workshop, title: "You're no longer subscribed to \(m.name)",
                                        detail: "Its files are still on disk, but Steam won't update it any more.", mods: [m.path],
                                        link: URL(string: "steam://url/CommunityFilePage/\(id)"), linkLabel: "Open in Steam"))
                }
            }
            if let info = index.online[id] {
                if info.isBanned {
                    issues.append(Issue(severity: .warning, category: .workshop, title: "\(m.name) was banned from the Workshop",
                                        detail: "Steam pulled it, usually for stolen or broken content. It won't get updates.", mods: [m.path]))
                } else if info.isRemoved {
                    issues.append(Issue(severity: .info, category: .workshop, title: "\(m.name) was removed from the Workshop",
                                        detail: "It still works from your copy, but it won't get updates and other players can't download it.",
                                        mods: [m.path]))
                }
            }
        }

        // Mods with nothing to load (not compositions or legacy items, which are fine).
        for m in enabled where index.emptyMods.contains(m.path) {
            issues.append(Issue(severity: .warning, category: .workshop, title: "\(m.name) has no game files",
                                detail: "There's nothing Arma can load in it. It's probably an incomplete download: unsubscribe and resubscribe in Steam.",
                                mods: [m.path], fix: .disable([m.path]), fixLabel: "Disable"))
        }

        // Cited known incompatibilities and superseded mods.
        let on = Set(enabled.map(\.path))
        let known = KnownIssues.evaluate(addonsByMod: index.addons.filter { on.contains($0.key) },
                                         workshopIDByMod: ids.filter { on.contains($0.key) },
                                         nameByMod: names.filter { on.contains($0.key) })
        for k in known {
            issues.append(Issue(severity: Issue.Severity(rawValue: k.severity.rawValue) ?? .info, category: .knownIssues,
                                title: k.title, detail: k.message, mods: k.mods,
                                fix: k.disable.isEmpty ? nil : .disable(k.disable),
                                fixLabel: k.disable.isEmpty ? "" : "Disable \(list(k.disable))",
                                link: URL(string: k.sourceURL), linkLabel: "Source"))
        }
        // A cited rule explains a bundle/superseded/exclusive overlap better than the raw "share N addons".
        let knownMods = Set(known.flatMap(\.mods))
        let covered = Set(duplicates.filter { Set($0.mods).isSubset(of: knownMods) }.map(\.id))
        issues.removeAll { covered.contains($0.id) }

        // Signatures only matter on servers that verify them, so they stay informational.
        for m in enabled {
            let blocking = (index.signatures[m.path]?.findings ?? []).filter { [.unsigned, .invalidSignature, .keyMismatch].contains($0.kind) }
            guard !blocking.isEmpty else { continue }
            issues.append(Issue(severity: .info, category: .multiplayer, title: "\(m.name) won't pass server signature checks",
                                detail: "Fine in single player and on servers that don't verify signatures; servers that do will kick you. " + blocking[0].message,
                                mods: [m.path], evidence: blocking.flatMap { [$0.message] + $0.files.prefix(3) }))
        }

        // What the game itself reported in the last session.
        if let log = index.lastSession {
            for e in log.failedExtensions {
                guard let p = e.modPath, on.contains(p) else { continue }
                issues.append(Issue(severity: .warning, category: .session, title: "\(name(p))'s extension failed to load",
                                    detail: "\(e.dll) didn't load last session, so features that rely on it won't work.",
                                    mods: [p], evidence: [e.detail]))
            }
            for miss in log.modMissingAddons {
                guard let p = miss.modPath, on.contains(p), configMissing[p] == nil else { continue }
                issues.append(Issue(severity: .error, category: .session, title: "Arma 3 refused to load part of \(name(p))",
                                    detail: "Last session it needed '\(miss.addon)', which wasn't loaded.", mods: [p], evidence: [miss.raw]))
            }
            let errors = (log.configErrors + log.scriptErrors).filter { $0.modPath.map(on.contains) ?? false }
            for (p, lines) in Dictionary(grouping: errors, by: { $0.modPath! }) {
                issues.append(Issue(severity: .warning, category: .session, title: "\(name(p)) reported errors last session",
                                    detail: "\(lines.count) error\(lines.count == 1 ? "" : "s") in the game log mention this mod.",
                                    mods: [p], evidence: lines.prefix(6).map(\.line)))
            }
        }

        if enabled.count > 120 {
            issues.append(Issue(severity: .info, category: .playset, title: "\(enabled.count) mods enabled",
                                detail: "Very large playsets load slowly and use a lot of memory. Arma 3 on Mac is more stable with a focused playset for each kind of mission."))
        }
        return issues.sorted { $0.severity != $1.severity ? $0.severity > $1.severity : ($0.confidence ?? 1) > ($1.confidence ?? 1) }
    }
}

// MARK: - Crash reports

struct CrashInfo {
    let secondsAfterLaunch: TimeInterval
    let report: URL?
    let culprit: String?   // non-game library at the top of the crashed thread, if any
    /// Set when the Apple Silicon build failed in a way the Intel build avoids; replaces the generic advice.
    var nativeFailure: (title: String, detail: String)? = nil

    var issue: Issue {
        if let nativeFailure {
            return Issue(severity: .error, category: .session, title: nativeFailure.title, detail: nativeFailure.detail)
        }
        let when = secondsAfterLaunch < 90 ? "\(Int(secondsAfterLaunch)) s" : "\(Int(secondsAfterLaunch / 60)) min"
        var detail: String
        if secondsAfterLaunch < 10 {
            detail = "It closed while starting, before any mods loaded, so this is rarely a mod problem. Make sure Steam is running and signed in, then try again. If it keeps happening, try the Balanced performance profile and clear custom parameters."
        } else if secondsAfterLaunch < 60 {
            detail = "It crashed while loading. Fix any problems listed below first; a launch option or a broken mod download are the usual causes."
        } else {
            detail = "Fix the problems listed below first. If nothing is listed, try a smaller playset to narrow down which mod is responsible."
        }
        if let culprit { detail = "The crash happened inside \(culprit). " + detail }
        return Issue(severity: .error, category: .session, title: "Arma 3 crashed \(when) after launch", detail: detail)
    }

    /// Looks for a macOS crash report for either Arma 3 build written since `since`.
    static func find(since: Date) -> (URL, String?)? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        guard let report = files
            .filter({ $0.lastPathComponent.hasPrefix("ArmA3") && $0.pathExtension == "ips" })
            .compactMap({ u -> (URL, Date)? in
                guard let d = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d >= since else { return nil }
                return (u, d)
            })
            .max(by: { $0.1 < $1.1 })?.0 else { return nil }
        return (report, culprit(in: report))
    }

    /// .ips = one JSON header line + a JSON body with threads and loaded images.
    private static func culprit(in report: URL) -> String? {
        guard let text = try? String(contentsOf: report, encoding: .utf8),
              let nl = text.firstIndex(of: "\n"),
              let body = try? JSONSerialization.jsonObject(with: Data(text[text.index(after: nl)...].utf8)) as? [String: Any],
              let threads = body["threads"] as? [[String: Any]],
              let crashed = threads.first(where: { $0["triggered"] as? Bool == true }),
              let frames = crashed["frames"] as? [[String: Any]],
              let images = body["usedImages"] as? [[String: Any]] else { return nil }
        for f in frames.prefix(8) {
            guard let idx = f["imageIndex"] as? Int, idx < images.count else { continue }
            let path = images[idx]["path"] as? String ?? ""
            let name = images[idx]["name"] as? String ?? ""
            if name.hasPrefix("ArmA3") || path.hasPrefix("/System") || path.hasPrefix("/usr") || name.isEmpty { continue }
            return name
        }
        return nil
    }
}
