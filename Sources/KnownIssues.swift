// Hand-curated knowledge about mods: documented incompatibilities, superseded or bundled mods,
// Mac-specific limits and Creator DLC requirements. Every rule names the page its claim comes from
// (an author's own Workshop text or readme); anything without a citation or a mechanism Kitbag can
// check against the mod's own addons does not belong here.
import Foundation

// MARK: - Rules

/// Identifies one mod by any of its markers: a Workshop ID, a CfgPatches class name, or (as a last
/// resort) its name. A mod matches when any marker matches.
struct ModMatcher: Codable, Hashable {
    var workshopIDs: [String] = []
    /// Exact CfgPatches class names, lowercased.
    var addons: [String] = []
    /// Lowercased CfgPatches name prefixes.
    var addonPrefixes: [String] = []
    /// Case-insensitive regular expression over the mod's name.
    var nameRegex: String?

    func matches(workshopID: String?, provided: Set<String>, name: String?) -> Bool {
        if let id = workshopID, workshopIDs.contains(id) { return true }
        if !addons.isEmpty, !provided.isDisjoint(with: addons) { return true }
        if !addonPrefixes.isEmpty, provided.contains(where: { a in addonPrefixes.contains { a.hasPrefix($0) } }) { return true }
        if let rx = nameRegex, let name, name.range(of: rx, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        return false
    }
}

struct KnownIssueRule: Codable, Hashable {
    enum Kind: String, Codable {
        /// `a` and `b` together cause trouble; neither is obviously the one to drop.
        case conflict
        /// `a` is replaced by `b` (merged into it, renamed or deprecated in its favour).
        case supersededBy
        /// `a` is a standalone part that the bundle `b` already contains.
        case partOf
        /// `a` has a documented problem on its own.
        case note
    }
    enum Severity: Int, Codable, Comparable {
        case info, warning, error
        static func < (x: Severity, y: Severity) -> Bool { x.rawValue < y.rawValue }
    }
    enum Category: String, Codable { case exclusive, superseded, bundle, macLimit }

    let id: String
    let kind: Kind
    let category: Category
    let severity: Severity
    let a: ModMatcher
    let b: ModMatcher?
    /// `{a}` and `{b}` are replaced with the names of the mods involved.
    let title: String
    let message: String
    /// Whether the remedy is to turn `a` off (it is redundant or obsolete). Never set for `.conflict`.
    let disablesA: Bool
    /// Where the claim comes from: the author's page, readme or the platform's documentation.
    let sourceURL: String
}

struct KnownIssueFinding: Codable, Hashable, Identifiable {
    let ruleID: String
    let kind: KnownIssueRule.Kind
    let category: KnownIssueRule.Category
    let severity: KnownIssueRule.Severity
    let title: String
    let message: String
    /// Keys (as passed to `evaluate`) of every mod the finding is about, sorted.
    let mods: [String]
    /// Keys of mods the rule says are redundant or obsolete; empty when the choice is the user's.
    let disable: [String]
    let sourceURL: String
    var id: String { ruleID + "|" + mods.joined(separator: "|") }
}

// MARK: - Creator DLC

struct CreatorDLC: Codable, Hashable {
    let name: String
    /// The folder / `-mod=` flag the DLC is loaded with.
    let flag: String
    let steamAppID: Int
    /// The free "Compatibility Data for Non-Owners" Workshop item that provides the DLC's addons.
    let compatibilityDataID: String

    var compatibilityDataURL: String { "https://steamcommunity.com/sharedfiles/filedetails/?id=\(compatibilityDataID)" }
}

// MARK: - Knowledge base

enum KnownIssues {
    private static func workshop(_ id: String) -> String { "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)" }

    private static let tfar = ModMatcher(workshopIDs: ["620019431", "894678801"], addons: ["task_force_radio", "tfar_core"])
    private static let acre2 = ModMatcher(workshopIDs: ["751965892"], addons: ["acre_main", "acre_api"])
    private static let lambsDanger = ModMatcher(workshopIDs: ["1858075458"], addons: ["lambs_danger"])
    private static let ace = ModMatcher(workshopIDs: ["463939057"], addons: ["ace_main"])

    static let rules: [KnownIssueRule] = [
        // Mutually exclusive families
        .init(id: "tfar-vs-acre2", kind: .conflict, category: .exclusive, severity: .warning, a: tfar, b: acre2,
              title: "{a} and {b} are competing radio mods",
              message: "Both replace Arma's voice and radio with a TeamSpeak plugin. TFAR's readme tells you to disable ACRE and similar radio plugins to avoid conflicts, so run only one of them.",
              disablesA: false, sourceURL: "https://github.com/michail-nikolaev/task-force-arma-3-radio/wiki/README_EN"),
        .init(id: "lambs-danger-vs-asr-ai3", kind: .conflict, category: .exclusive, severity: .warning, a: lambsDanger,
              b: ModMatcher(workshopIDs: ["642457233"], addonPrefixes: ["asr_ai3"]),
              title: "{a} is not compatible with {b}",
              message: "The LAMBS Danger page lists ACE3 and VCOM as compatible, \"but unfortunately not ASR\". Use one AI overhaul or the other.",
              disablesA: false, sourceURL: workshop("1858075458")),
        .init(id: "vcom-b0s-vs-lambs-danger", kind: .conflict, category: .exclusive, severity: .warning,
              a: ModMatcher(workshopIDs: ["3583496722"]), b: lambsDanger,
              title: "{a} conflicts with {b}",
              message: "The VCOM AI b0s edit lists conflicts with LAMBS Danger: it states VCOM overwrites LAMBS Danger's FSM. (LAMBS' own page calls the original VCOM compatible.)",
              disablesA: false, sourceURL: workshop("3583496722")),
        .init(id: "jsrs-rhs-aio-vs-single-packs", kind: .conflict, category: .exclusive, severity: .warning,
              a: ModMatcher(workshopIDs: ["2068033599"]), b: ModMatcher(addonPrefixes: ["jsrs_soundmod_rhs_", "jsrs_soundmod_cfg_rhs_"]),
              title: "{a} overlaps with {b}",
              message: "The JSRS RHS all-in-one pack contains the same sound patches as the single RHS packs, and its author says not to use it together with them.",
              disablesA: false, sourceURL: workshop("2068033599")),
        .init(id: "gx-drones-dev-vs-stable", kind: .conflict, category: .exclusive, severity: .warning,
              a: ModMatcher(workshopIDs: ["3563903841"]), b: ModMatcher(workshopIDs: ["3460981677"], addonPrefixes: ["gx_drones"]),
              title: "{a} should not run next to {b}",
              message: "The development build of GX - Drones says it should not be loaded together with the main stable version because of possible conflicts.",
              disablesA: false, sourceURL: workshop("3563903841")),
        .init(id: "blastcore-murr-vs-other-blastcore", kind: .conflict, category: .exclusive, severity: .warning,
              a: ModMatcher(workshopIDs: ["2257686620"]), b: ModMatcher(addons: ["warfxpe", "warfxpe_weps"], addonPrefixes: ["blastcore"]),
              title: "{a} conflicts with {b}",
              message: "Blastcore Murr Edition says to disable all other Blastcore or ArmaFXP related mods to avoid conflicts. The others here are edits of Blastcore: they define its WarFXPE addons or carry Blastcore in their addon names.",
              disablesA: false, sourceURL: workshop("2257686620")),
        .init(id: "apex-drakon-vs-ace", kind: .conflict, category: .exclusive, severity: .info,
              a: ModMatcher(workshopIDs: ["530168603"]), b: ace,
              title: "{a} doesn't work with ACE's missile system",
              message: "The author's page (from 2015) says the Drakon doesn't work with ACE's missile system and advises not using it with ACE. That note is old, so the weapons may behave differently now.",
              disablesA: false, sourceURL: workshop("530168603")),
        .init(id: "firewill-variant-vs-complete", kind: .conflict, category: .exclusive, severity: .warning,
              a: ModMatcher(workshopIDs: ["1794848554"]), b: ModMatcher(workshopIDs: ["1381545544"]),
              title: "{a} is a variant of {b}",
              message: "The helicopter edition is a variant of the Complete pack and its page says you probably do not need both. Both define the same aircraft addons.",
              disablesA: false, sourceURL: workshop("1794848554")),

        // Bundles and their parts
        .init(id: "usp-gear-aio-contains-standalone-packs", kind: .partOf, category: .bundle, severity: .warning,
              a: ModMatcher(workshopIDs: ["2044374502", "2049719091", "2113786615", "2117772824", "2123454851", "2365500050"],
                            addons: ["usp_cbaeh_fix", "usp_gear_acc", "usp_gear_body", "usp_gear_core", "usp_gear_face",
                                     "usp_gear_head", "usp_gear_nvg", "usp_gear_pack", "usp_gear_vest"]),
              b: ModMatcher(workshopIDs: ["1795825073"]),
              title: "{a} is already inside {b}",
              message: "The all-in-one pack contains every standalone USP Gear module and its page says it needs none of them; the standalone pages say they don't need the AIO either. Loading both defines the same addons twice.",
              disablesA: true, sourceURL: workshop("1795825073")),

        // Superseded, deprecated or obsolete
        .init(id: "aas-modules-merged-into-core", kind: .supersededBy, category: .superseded, severity: .warning,
              a: ModMatcher(workshopIDs: ["3710631688", "3712468535", "3717486591"]), b: ModMatcher(workshopIDs: ["3699105433"]),
              title: "{a} is built into {b}",
              message: "The module is deprecated: its page says all features are now built directly into AAS - Core and the module is no longer necessary. It still defines the same addons as Core.",
              disablesA: true, sourceURL: workshop("3710631688")),
        .init(id: "jsrs-legacy-addons-vs-2025", kind: .supersededBy, category: .superseded, severity: .warning,
              a: ModMatcher(addonPrefixes: ["jsrs_soundmod_"]), b: ModMatcher(workshopIDs: ["3407948300"], addonPrefixes: ["jsrs2025_"]),
              title: "{a} belongs to the old JSRS SOUNDMOD",
              message: "This belongs to the older JSRS SOUNDMOD (its add-ons require the jsrs_soundmod_complete_edition addon), which JSRS SOUNDMOD 2025 replaces. JSRS 2025 includes its own compatibility for CUP, RHS and others, so the old add-on is redundant and can't load without the old base mod.",
              disablesA: true, sourceURL: workshop("3407948300")),
        .init(id: "simplex-support-deprecated-listing", kind: .note, category: .superseded, severity: .info,
              a: ModMatcher(workshopIDs: ["1850026051"]), b: nil,
              title: "{a} is a deprecated Workshop listing",
              message: "Its page says the listing is deprecated and only kept for prior dependencies, and points to Workshop item 3029520419 as the latest version. Keep it only if another mod still requires it.",
              disablesA: false, sourceURL: workshop("1850026051")),
        .init(id: "armazeuscache-obsolete", kind: .note, category: .superseded, severity: .info,
              a: ModMatcher(workshopIDs: ["1908099028"], addons: ["armazeuscache"]), b: nil,
              title: "{a} is obsolete",
              message: "Its author says the mod was integrated into Arma 3 itself with version 2.00 and is now obsolete.",
              disablesA: true, sourceURL: workshop("1908099028")),
        .init(id: "achilles-superseded-by-zen", kind: .note, category: .superseded, severity: .info,
              a: ModMatcher(workshopIDs: ["723217262"], addonPrefixes: ["achilles_"]), b: nil,
              title: "{a} is no longer developed",
              message: "Its developers state that Achilles is no longer under active development and recommend Zeus Enhanced (ZEN) instead.",
              disablesA: false, sourceURL: workshop("723217262")),

        // Mac
        .init(id: "radio-mods-need-teamspeak-plugin", kind: .note, category: .macLimit, severity: .info,
              a: ModMatcher(workshopIDs: tfar.workshopIDs + acre2.workshopIDs, addons: tfar.addons + acre2.addons), b: nil,
              title: "{a} depends on a TeamSpeak 3 plugin",
              message: "Radio and voice features are not handled by Arma itself but by a TeamSpeak 3 plugin that the mod's page describes installing into a TeamSpeak client (copied at game start, or by double-clicking the plugin file). Kitbag can't confirm that works with Arma 3 on a Mac, so radio transmissions and voice may not work even though the addon loads.",
              disablesA: false, sourceURL: workshop("751965892")),
    ]

    // MARK: Evaluation

    /// Applies every rule to the given mods. Keys are whatever the caller uses to identify a mod
    /// (typically its folder path); pass only the mods that are enabled. Addon names are lowercased
    /// CfgPatches class names.
    static func evaluate(addonsByMod: [String: Set<String>], workshopIDByMod: [String: String],
                         nameByMod: [String: String]) -> [KnownIssueFinding] {
        let keys = Set(addonsByMod.keys).union(workshopIDByMod.keys).union(nameByMod.keys).sorted()
        let provided = addonsByMod.mapValues { Set($0.map { $0.lowercased() }) }
        func label(_ key: String) -> String {
            nameByMod[key] ?? workshopIDByMod[key].map { "Workshop item \($0)" } ?? key
        }
        func matching(_ m: ModMatcher) -> [String] {
            keys.filter { m.matches(workshopID: workshopIDByMod[$0], provided: provided[$0] ?? [], name: nameByMod[$0]) }
        }
        func names(_ ks: [String]) -> String { ks.map(label).joined(separator: ", ") }
        func make(_ r: KnownIssueRule, a: [String], b: [String], mods: [String], disable: [String]) -> KnownIssueFinding {
            func fill(_ s: String) -> String { s.replacingOccurrences(of: "{a}", with: names(a)).replacingOccurrences(of: "{b}", with: names(b)) }
            return KnownIssueFinding(ruleID: r.id, kind: r.kind, category: r.category, severity: r.severity,
                                     title: fill(r.title), message: fill(r.message), mods: Array(Set(mods)).sorted(),
                                     disable: Array(Set(disable)).sorted(), sourceURL: r.sourceURL)
        }

        var out: [KnownIssueFinding] = []
        for r in rules {
            let aMods = matching(r.a)
            guard !aMods.isEmpty else { continue }
            let bMods = r.b.map(matching) ?? []
            switch r.kind {
            case .conflict:
                // One finding for the whole group, as long as the two sides are different mods.
                let pairA = aMods.filter { x in bMods.contains { $0 != x } }
                let pairB = bMods.filter { y in aMods.contains { $0 != y } }
                if !pairA.isEmpty, !pairB.isEmpty {
                    out.append(make(r, a: pairA, b: pairB, mods: pairA + pairB, disable: []))
                }
            case .supersededBy:
                for x in aMods {
                    let newer = bMods.filter { $0 != x }
                    if !newer.isEmpty { out.append(make(r, a: [x], b: newer, mods: [x] + newer, disable: r.disablesA ? [x] : [])) }
                }
            case .partOf:
                for x in aMods {
                    let mine = provided[x] ?? []
                    // A known part must really be a subset of the bundle; otherwise this version isn't what the page describes.
                    let bundles = bMods.filter { $0 != x && mine.isSubset(of: provided[$0] ?? []) }
                    if !bundles.isEmpty { out.append(make(r, a: [x], b: bundles, mods: [x] + bundles, disable: r.disablesA ? [x] : [])) }
                }
            case .note:
                for x in aMods { out.append(make(r, a: [x], b: [], mods: [x], disable: r.disablesA ? [x] : [])) }
            }
        }
        return out.sorted { $0.severity != $1.severity ? $0.severity > $1.severity : $0.id < $1.id }
    }

    /// Problems in the rule table itself (empty when it is sound): duplicate ids, rules without a
    /// source, empty matchers, bad regular expressions, a `b` side that doesn't fit the kind.
    static func selfCheck() -> [String] {
        var problems: [String] = []
        var seen = Set<String>()
        func empty(_ m: ModMatcher) -> Bool { m.workshopIDs.isEmpty && m.addons.isEmpty && m.addonPrefixes.isEmpty && m.nameRegex == nil }
        for r in rules {
            if !seen.insert(r.id).inserted { problems.append("duplicate id \(r.id)") }
            if URL(string: r.sourceURL)?.scheme != "https" { problems.append("\(r.id): no https source") }
            if empty(r.a) || (r.b.map(empty) ?? false) { problems.append("\(r.id): empty matcher") }
            if (r.kind == .note) != (r.b == nil) { problems.append("\(r.id): b side doesn't fit kind \(r.kind)") }
            if r.kind == .conflict && r.disablesA { problems.append("\(r.id): conflicts must leave the choice to the user") }
            for m in [r.a, r.b].compactMap({ $0 }) {
                if m.addons.contains(where: { $0 != $0.lowercased() }) || m.addonPrefixes.contains(where: { $0 != $0.lowercased() }) {
                    problems.append("\(r.id): addon names must be lowercase")
                }
                if let rx = m.nameRegex, (try? NSRegularExpression(pattern: rx)) == nil { problems.append("\(r.id): bad regex") }
            }
        }
        return problems
    }

    // MARK: Creator DLC

    /// The seven Arma 3 Creator DLCs (names, flags and Steam IDs from the BI wiki's CDLC category and
    /// the arma3.com Creator DLC page; compatibility data IDs from the Workshop).
    static let creatorDLCs: [CreatorDLC] = [
        .init(name: "Global Mobilization - Cold War Germany", flag: "gm", steamAppID: 1042220, compatibilityDataID: "1776428269"),
        .init(name: "S.O.G. Prairie Fire", flag: "vn", steamAppID: 1227700, compatibilityDataID: "2477276806"),
        .init(name: "CSLA Iron Curtain", flag: "csla", steamAppID: 1294440, compatibilityDataID: "2503886780"),
        .init(name: "Western Sahara", flag: "ws", steamAppID: 1681170, compatibilityDataID: "2636962953"),
        .init(name: "Spearhead 1944", flag: "spe", steamAppID: 1175380, compatibilityDataID: "2991828484"),
        .init(name: "Reaction Forces", flag: "rf", steamAppID: 2647760, compatibilityDataID: "3150497912"),
        .init(name: "Expeditionary Forces", flag: "ef", steamAppID: 2647830, compatibilityDataID: "3348605126"),
    ]

    /// How each DLC names its CfgPatches classes, taken from the `requiredAddons` of mods that load after
    /// them: ACRE2's compat_* addons (github.com/IDI-Systems/acre2/tree/master/addons: `gm_core`, `CSLA`,
    /// `loadorder_f_vietnam`, `data_f_lxWS_Loadorder`, `WW2_SPE_Assets_c_Vehicles_ZZZ_LastLoaded_c`) and the
    /// copies of ACE3, JSRS 2025 and GX - Drones installed here (`csla_air`, `ef_marines`, `ef_weapons`,
    /// `rf_data_loadorder`, `rf_air`, …). Prairie Fire's `vn_` prefix rests only on the BI wiki's class tag and
    /// Workshop reports of `vn_rifle762` / `vn_lmg` patches.
    private static let dlcAddonNames: [(flag: String, exact: [String], prefixes: [String], infixes: [String])] = [
        ("gm", [], ["gm_"], []),
        ("vn", [], ["vn_"], ["_f_vietnam"]),
        ("csla", ["csla"], ["csla_"], []),
        ("ws", [], ["lxws_"], ["_lxws"]),
        ("spe", [], ["ww2_spe_", "ww2_fixes_spe_"], []),
        ("rf", [], ["rf_"], []),
        ("ef", [], ["ef_"], []),
    ]

    /// The Creator DLC an addon belongs to. Meant for addons that are required but provided by no
    /// installed mod and not by the base game, and whose patch doesn't set `skipWhenMissingDependencies`
    /// (ACE3, ACRE2 and JSRS 2025 list DLC addons only to load after them when present). A third-party
    /// mod that happens to use the same prefix would be misattributed, so word the result as "belongs to".
    static func creatorDLC(forAddon addon: String) -> String? {
        creatorDLCInfo(forAddon: addon)?.name
    }

    /// The Creator DLCs one mod really needs, with the addons it is missing from each: required addons that
    /// `isAvailable` says nothing provides (base game, installed mods), that belong to a DLC, and that sit
    /// in a patch without `skipWhenMissingDependencies`. Without the DLC (or its free compatibility data)
    /// Arma 3 reports those addons as missing and refuses to load the patch.
    static func creatorDLCRequirements(of patches: [PatchInfo], isAvailable: (String) -> Bool) -> [CreatorDLC: [String]] {
        let own = Set(patches.map(\.name))
        var out: [CreatorDLC: Set<String>] = [:]
        for p in patches where !p.skipWhenMissingDependencies {
            for r in p.requiredAddons where !own.contains(r) && !isAvailable(r) {
                if let dlc = creatorDLCInfo(forAddon: r) { out[dlc, default: []].insert(r) }
            }
        }
        return out.mapValues { $0.sorted() }
    }

    static func creatorDLCInfo(forAddon addon: String) -> CreatorDLC? {
        let a = addon.lowercased()
        guard let hit = dlcAddonNames.first(where: { d in
            d.exact.contains(a) || d.prefixes.contains { a.hasPrefix($0) } || d.infixes.contains { a.hasSuffix($0) || a.contains($0 + "_") }
        }) else { return nil }
        return creatorDLCs.first { $0.flag == hit.flag }
    }
}
