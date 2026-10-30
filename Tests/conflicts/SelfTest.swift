// Synthetic libraries that pin down the merge rules: every finding kind, and the cases that must stay quiet.
import Foundation

enum SelfTest {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var checks = 0

    static func check(_ cond: Bool, _ msg: @autoclosure () -> String, file: StaticString = #fileID, line: UInt = #line) {
        checks += 1
        if !cond { failures += 1; print("  FAIL (line \(line)): \(msg())") }
    }

    // MARK: Builders

    static func patch(_ name: String, req: [String] = [], skip: Bool = false) -> PatchInfo {
        PatchInfo(name: name.lowercased(), requiredAddons: req.map { $0.lowercased() }, requiredVersion: nil, skipWhenMissingDependencies: skip)
    }

    static func cls(_ path: String, _ parent: String? = nil, props: [String: String] = [:], external: Bool = false) -> ClassDef {
        ClassDef(path: path.lowercased(), parent: parent?.lowercased(), external: external, props: props, deletes: [])
    }

    static func pbo(_ mod: String, _ name: String, prefix: String = "", size: Int64 = 1000, patches: [PatchInfo] = [], classes: [ClassDef] = [],
                    probes: [String: Bool] = [:]) -> PBOSummary {
        var s = ConfigSummary()
        s.patches = patches; s.classes = classes
        return PBOSummary(path: "/lib/\(mod)/addons/\(name).pbo", size: size, mtime: 0, prefix: prefix, summary: s, hasIncludeProbes: probes, configFiles: ["config.bin"])
    }

    static func vanilla(addons: [String], defined: [(String, String)] = [], declared: [String] = []) -> VanillaIndex {
        var v = VanillaIndex()
        v.addons = Set(addons.map { $0.lowercased() })
        for (p, b) in defined { v.parents[p.lowercased()] = b.lowercased() }
        for p in declared { v.parents[p.lowercased()] = ""; v.externalOnly.insert(p.lowercased()) }
        return v
    }

    static func library(_ v: VanillaIndex, _ mods: [(String, [PBOSummary])]) -> (GameIndex, [String: String]) {
        var idx = GameIndex()
        idx.vanilla = v
        var names: [String: String] = [:]
        for (m, pbos) in mods {
            let path = "/lib/\(m)"
            idx.mods[path] = ModSummary(path: path, hasAddonsFolder: true, pbos: pbos, windowsOnlyExtensions: [], macExtensions: [])
            idx.modOrder.append(path)
            names[path] = m
        }
        return (idx, names)
    }

    static let baseVanilla = vanilla(
        addons: ["A3_Data_F", "A3_Weapons_F"],
        defined: [("cfgvehicles", ""), ("cfgvehicles/allvehicles", ""), ("cfgvehicles/car", "allvehicles"), ("cfgvehicles/car_f", "car"),
                  ("cfgvehicles/car_f/turrets", ""), ("cfgvehicles/car_f/turrets/mainturret", ""),
                  ("cfgweapons", ""), ("cfgweapons/rifle_base_f", ""), ("cfgweapons/arifle_mx_f", "rifle_base_f"),
                  ("rsctext", ""), ("cfgvehicles/landvehicle", "land"), ("cfgvehicles/land", "allvehicles")],
        declared: ["cfgvehicles/landvehicle/sounds"])

    static func run() -> Bool {
        let tests: [(String, () -> Void)] = [
            ("missing dependencies", missingDependencies), ("skipWhenMissingDependencies", skipWhenMissing), ("undefined base classes", undefinedBases),
            ("base class resolution rules", resolutionRules), ("forward declarations and placeholders", placeholders), ("base class changes", baseChanges), ("property fights", propertyFights),
            ("duplicates and prefixes", duplicates), ("conditional configs", conditional), ("general", general),
        ]
        for (name, body) in tests {
            let before = failures
            body()
            print("\(failures == before ? "ok  " : "FAIL") \(name)")
        }
        print("\(checks) checks, \(failures) failed")
        return failures == 0
    }

    static func findings(_ ctx: ConflictContext, _ enabled: [String], _ kind: ConflictFinding.Kind? = nil) -> [ConflictFinding] {
        ctx.analyze(enabled: enabled.map { "/lib/\($0)" }).filter { kind == nil || $0.kind == kind }
    }

    // MARK: Missing dependencies

    static func missingDependencies() {
        let (idx, names) = library(baseVanilla, [
            ("A", [pbo("A", "a", patches: [patch("a_main", req: ["b_main", "A3_Data_F"])])]),
            ("B", [pbo("B", "b", patches: [patch("b_main")])]),
            ("C", [pbo("C", "c1", patches: [patch("c_main")]), pbo("C", "c2", patches: [patch("c_two", req: ["c_main"])])]),
            ("D", [pbo("D", "d", patches: [patch("d_main", req: ["gm_core"])])]),
            ("E", [pbo("E", "e", patches: [patch("e_main", req: ["nobody_provides_this"])])]),
            ("F", [pbo("F", "f", patches: [patch("f_main", req: ["B_MAIN"])])]),
        ])
        let ctx = ConflictContext(index: idx, names: names)
        var f = findings(ctx, ["A"], .missingDependency)
        check(f.count == 1 && f[0].severity == .error, "A alone: one error, got \(f.map(\.title))")
        check(f.first?.suggestedEnable == ["/lib/B"], "suggests the disabled provider B, got \(f.first?.suggestedEnable ?? [])")
        check(f.first?.title.contains("needs B") == true, "title names B: \(f.first?.title ?? "")")
        check(findings(ctx, ["A", "B"], .missingDependency).isEmpty, "A with B enabled is fine (vanilla addon A3_Data_F satisfied by the game)")
        check(findings(ctx, ["C"], .missingDependency).isEmpty, "a mod's own second PBO provides c_main")
        f = findings(ctx, ["D"], .missingDependency)
        check(f.count == 1 && f[0].title.contains("Global Mobilization") && f[0].suggestedEnable.isEmpty, "Creator DLC named: \(f.map(\.title))")
        f = findings(ctx, ["E"], .missingDependency)
        check(f.count == 1 && f[0].suggestedEnable.isEmpty && f[0].evidence.first?.contains("no installed mod") == true, "unknown addon has no suggestion: \(f.map(\.evidence))")
        check(findings(ctx, ["F", "B"], .missingDependency).isEmpty, "requiredAddons match is case-insensitive")
    }

    static func skipWhenMissing() {
        let (idx, names) = library(baseVanilla, [
            ("A", [pbo("A", "a1", patches: [patch("a_compat", req: ["b_main"], skip: true)],
                       classes: [cls("cfgvehicles/a_car", "b_base")]),
                   pbo("A", "a2", patches: [patch("a_main")])]),
            ("B", [pbo("B", "b", patches: [patch("b_main")], classes: [cls("cfgvehicles/b_base", "car")])]),
            ("C", [pbo("C", "c", patches: [patch("c_main", req: ["a_compat"])])]),
        ])
        let ctx = ConflictContext(index: idx, names: names)
        check(findings(ctx, ["A"]).isEmpty, "A alone: compat addon silently skipped, and its classes with a missing base are not reported: \(findings(ctx, ["A"]).map(\.title))")
        check(findings(ctx, ["A", "B"]).filter { $0.kind != .propertyConflict }.isEmpty, "A with B: compat loads, nothing wrong")
        let f = findings(ctx, ["C", "A"], .missingDependency)
        check(f.count == 1 && f[0].modPaths.first == "/lib/C", "C needs a_compat, which is skipped: \(f.map(\.title))")
        check(f.first?.evidence.first?.contains("b_main") == true || f.first?.evidence.first?.contains("skipped") == true, "explains the skip: \(f.first?.evidence ?? [])")
        check(f.first?.suggestedEnable == ["/lib/B"], "root cause: enabling B, got \(f.first?.suggestedEnable ?? [])")
    }

    // MARK: Undefined base classes

    static func undefinedBases() {
        let (idx, names) = library(baseVanilla, [
            ("A", [pbo("A", "a", patches: [patch("a_main")], classes: [
                cls("cfgvehicles/a_car", "car_f"), cls("cfgvehicles/a_van", "b_van_base"), cls("cfgvehicles/a_ghost", "ghost_base")])]),
            ("B", [pbo("B", "b", patches: [patch("b_main")], classes: [cls("cfgvehicles/b_van_base", "car_f")])]),
        ])
        let ctx = ConflictContext(index: idx, names: names)
        var f = findings(ctx, ["A"], .undefinedBaseClass)
        check(f.count == 2, "A alone: two findings, got \(f.map(\.title))")
        let disabled = f.first { !$0.suggestedEnable.isEmpty }
        check(disabled?.severity == .error && disabled?.suggestedEnable == ["/lib/B"], "base in disabled B: error with suggestion, got \(String(describing: disabled?.title))")
        let nowhere = f.first { $0.suggestedEnable.isEmpty }
        check(nowhere?.severity == .info && nowhere?.evidence.first?.contains("ghost_base") == true, "base nowhere: info without suggestion, got \(String(describing: nowhere?.title))")
        f = findings(ctx, ["A", "B"], .undefinedBaseClass)
        check(f.count == 1 && f[0].evidence.first?.contains("ghost_base") == true, "with B only the ghost remains: \(f.map(\.evidence))")
    }

    static func resolutionRules() {
        // Same-name inheritance, enclosing scopes and declared-only classes all resolve like in the base game.
        let (idx, names) = library(baseVanilla, [
            ("M", [pbo("M", "m", patches: [patch("m_main")], classes: [
                cls("cfgvehicles/m_car", "car_f"),
                cls("cfgvehicles/m_car/turrets", "turrets"),
                cls("cfgvehicles/m_car/turrets/mainturret", "mainturret"),
                cls("mydialog"), cls("mydialog/controls"), cls("mydialog/controls/title", "rsctext"),
                cls("cfgvehicles/m_truck", "landvehicle"),
                cls("cfgvehicles/m_truck/sounds", "sounds"),
                cls("cfgvehicles/m_truck/sounds/engine_x", "engine"),
            ])]),
            ("Z", [pbo("Z", "z", patches: [patch("z_main")], classes: [
                cls("cfgvehicles/land/sounds"), cls("cfgvehicles/land/sounds/engine")])]),
        ])
        let ctx = ConflictContext(index: idx, names: names)
        let f = findings(ctx, ["M", "Z"], .undefinedBaseClass)
        check(f.isEmpty, "all resolvable, got \(f.map(\.evidence))")
        // Without the class that Z contributes, the declared-only Sounds has nothing to inherit.
        let g = findings(ctx, ["M"], .undefinedBaseClass)
        check(g.count == 1 && g[0].evidence.contains { $0.contains("'engine'") && $0.contains("1 class,") }, "engine not found without Z \(g.map(\.evidence))")
        check(ctx.vanillaResolutionFailures().failures.isEmpty, "the synthetic base game resolves against itself")
        // `class UserActions: UserActions` with no parent member to inherit is a common idiom the game copes with.
        let (idx2, n2) = library(baseVanilla, [("N", [pbo("N", "n", patches: [patch("n_main")], classes: [
            cls("cfgvehicles/n_car", "car_f"), cls("cfgvehicles/n_car/useractions", "useractions")])])])
        let g2 = findings(ConflictContext(index: idx2, names: n2), ["N"], .undefinedBaseClass)
        check(g2.isEmpty, "UserActions: UserActions with no parent member is not reported: \(g2.map(\.evidence))")
    }

    static func placeholders() {
        // A base the mod forward-declares where it uses it becomes an empty class in the game: no error, nothing to blame.
        let (idx, names) = library(baseVanilla, [
            ("A", [pbo("A", "a", patches: [patch("a_main")], classes: [
                cls("cfgvehicles/ghost_base", external: true), cls("cfgvehicles/a_ghost", "ghost_base"), cls("cfgvehicles/a_lost", "lost_base")])]),
        ])
        let f = findings(ConflictContext(index: idx, names: names), ["A"], .undefinedBaseClass)
        check(f.count == 1 && f[0].evidence.first?.contains("lost_base") == true && !f[0].evidence.joined().contains("ghost_base"), "declared base is quiet, undeclared reported: \(f.map(\.evidence))")
        // A forward declaration high up the scope chain counts too.
        let (idx2, n2) = library(baseVanilla, [
            ("A", [pbo("A", "a", patches: [patch("a_main")], classes: [cls("rsc_base", external: true), cls("mydialog"), cls("mydialog/title", "rsc_base")])]),
        ])
        check(findings(ConflictContext(index: idx2, names: n2), ["A"], .undefinedBaseClass).isEmpty, "declared in an enclosing scope is quiet")
        // ... and so does one in a base class's scope (`class Sounds: Sounds { class Idle: Idle_ext }` with `Idle_ext;` declared up the chain).
        let (idx5, n5) = library(baseVanilla, [
            ("A", [pbo("A", "a", patches: [patch("a_main")], classes: [
                cls("cfgvehicles/car_f/turrets/idle_ext", external: true), cls("cfgvehicles/a_car", "car_f"),
                cls("cfgvehicles/a_car/turrets", "turrets"), cls("cfgvehicles/a_car/turrets/fix", "idle_ext")])]),
        ])
        check(findings(ConflictContext(index: idx5, names: n5), ["A"], .undefinedBaseClass).isEmpty, "declared in a base class's scope is quiet")
        // An empty placeholder class in a disabled mod is no reason to turn that mod on.
        let (idx3, n3) = library(baseVanilla, [
            ("A", [pbo("A", "a", patches: [patch("a_main")], classes: [cls("cfgvehicles/a_x", "stub_base")])]),
            ("B", [pbo("B", "b", patches: [patch("b_main")], classes: [cls("cfgvehicles/stub_base")])]),
            ("C", [pbo("C", "c", patches: [patch("c_main")], classes: [cls("cfgvehicles/real_base", "car_f"), cls("cfgvehicles/c_y", "real_base")])]),
        ])
        let ctx3 = ConflictContext(index: idx3, names: n3)
        let g = findings(ctx3, ["A"], .undefinedBaseClass)
        check(g.count == 1 && g[0].suggestedEnable.isEmpty && g[0].severity == .info, "stub-only provider is not suggested: \(g.map(\.title))")
        let (idx4, n4) = library(baseVanilla, [
            ("A", [pbo("A", "a", patches: [patch("a_main")], classes: [cls("cfgvehicles/a_x", "real_base")])]),
            ("C", [pbo("C", "c", patches: [patch("c_main")], classes: [cls("cfgvehicles/real_base", "car_f")])]),
        ])
        let h = findings(ConflictContext(index: idx4, names: n4), ["A"], .undefinedBaseClass)
        check(h.count == 1 && h[0].suggestedEnable == ["/lib/C"], "a defined base is suggested: \(h.map(\.title))")
    }

    // MARK: Base class changes

    static func baseChanges() {
        let v = baseVanilla
        func mod(_ n: String, _ base: String, req: [String] = []) -> (String, [PBOSummary]) {
            (n, [pbo(n, n.lowercased(), patches: [patch("\(n.lowercased())_main", req: req)], classes: [cls("cfgweapons/arifle_mx_f", base)])])
        }
        // M changes the parent; nobody else names one: intended.
        var (idx, names) = library(v, [mod("M", "rifle_other_f")])
        var f = findings(ConflictContext(index: idx, names: names), ["M"], .baseClassChange)
        check(f.count == 1 && f[0].severity == .info, "lone change is informational: \(f.map(\.title))")
        // N restates the original base while M changes it, no dependency between them: a fight, blamed on M.
        (idx, names) = library(v, [mod("M", "rifle_other_f"), mod("N", "rifle_base_f")])
        f = findings(ConflictContext(index: idx, names: names), ["M", "N"], .baseClassChange)
        check(f.count == 1 && f[0].severity == .warning && f[0].modPaths.first == "/lib/M" && f[0].modPaths.contains("/lib/N"), "deviant M vs keeper N: \(f.map { ($0.title, $0.modPaths) })")
        // N depends on M: N loads after and its word is final.
        (idx, names) = library(v, [mod("M", "rifle_other_f"), mod("N", "rifle_base_f", req: ["m_main"])])
        f = findings(ConflictContext(index: idx, names: names), ["M", "N"], .baseClassChange).filter { $0.severity == .warning }
        check(f.isEmpty, "related mods do not fight: \(f.map(\.title))")
        // Two different new bases, unrelated: a pair finding.
        (idx, names) = library(v, [mod("M", "rifle_one_f"), mod("N", "rifle_two_f")])
        f = findings(ConflictContext(index: idx, names: names), ["M", "N"], .baseClassChange)
        check(f.contains { $0.severity == .warning && $0.title.contains("disagree") }, "pair disagreement: \(f.map(\.title))")
        // A third mod that depends on both settles it.
        (idx, names) = library(v, [mod("M", "rifle_one_f"), mod("N", "rifle_two_f"),
                                   ("C", [pbo("C", "c", patches: [patch("c_main", req: ["m_main", "n_main"])], classes: [cls("cfgweapons/arifle_mx_f", "rifle_one_f")])])])
        f = findings(ConflictContext(index: idx, names: names), ["M", "N", "C"], .baseClassChange).filter { $0.severity == .warning }
        check(f.isEmpty, "a compat mod that redefines the class settles it: \(f.map(\.title))")
        // A mod that depends on both but leaves the class alone does not.
        (idx, names) = library(v, [mod("M", "rifle_one_f"), mod("N", "rifle_two_f"), ("C", [pbo("C", "c", patches: [patch("c_main", req: ["m_main", "n_main"])])])])
        f = findings(ConflictContext(index: idx, names: names), ["M", "N", "C"], .baseClassChange).filter { $0.severity == .warning }
        check(f.count == 1, "a mod that merely depends on both leaves the order open: \(f.map(\.title))")
        // A redefinition without a base keeps the base.
        (idx, names) = library(v, [("P", [pbo("P", "p", patches: [patch("p_main")], classes: [cls("cfgweapons/arifle_mx_f", nil, props: ["armor": "1"])])]), mod("M", "rifle_other_f")])
        f = findings(ConflictContext(index: idx, names: names), ["M", "P"], .baseClassChange).filter { $0.severity == .warning }
        check(f.isEmpty, "no explicit base is no change: \(f.map(\.title))")
        // `class mx: mx` inherits the parent's member of that name; it does not name a new base.
        (idx, names) = library(v, [mod("M", "arifle_mx_f"), mod("N", "rifle_base_f")])
        check(findings(ConflictContext(index: idx, names: names), ["M", "N"], .baseClassChange).isEmpty, "a self-named base is no change")
        // The same base everywhere is not a change.
        (idx, names) = library(v, [mod("M", "rifle_base_f"), mod("N", "rifle_base_f")])
        check(findings(ConflictContext(index: idx, names: names), ["M", "N"], .baseClassChange).isEmpty, "restating the original base is nothing")
    }

    // MARK: Property fights

    static func propertyFights() {
        func mod(_ n: String, _ props: [String: String], req: [String] = [], path: String = "cfgweapons/arifle_mx_f", skip: Bool = false, extra: [ClassDef] = []) -> (String, [PBOSummary]) {
            (n, [pbo(n, n.lowercased(), patches: [patch("\(n.lowercased())_main", req: req, skip: skip)], classes: [cls(path, nil, props: props)] + extra)])
        }
        let v = baseVanilla
        func run(_ mods: [(String, [PBOSummary])], on: [String]) -> [ConflictFinding] {
            let (idx, names) = library(v, mods)
            return findings(ConflictContext(index: idx, names: names), on, .propertyConflict)
        }
        var f = run([mod("A", ["armor": "3"]), mod("B", ["armor": "5"])], on: ["A", "B"])
        check(f.count == 1 && f[0].evidence.first?.contains("cfgweapons/arifle_mx_f.armor") == true, "armor fight: \(f.map(\.evidence))")
        check(run([mod("A", ["armor": "3"]), mod("B", ["armor": "3"])], on: ["A", "B"]).isEmpty, "equal values do not fight")
        check(run([mod("A", ["author": "\"x\"", "timepacked": "\"1\""]), mod("B", ["author": "\"y\"", "timepacked": "\"2\""])], on: ["A", "B"]).isEmpty, "packing metadata is ignored")
        check(run([mod("A", ["displayname": "\"x\""]), mod("B", ["displayname": "\"y\""])], on: ["A", "B"]).isEmpty, "labels are ignored")
        check(run([mod("A", ["armor": "+={1}"]), mod("B", ["armor": "+={2}"])], on: ["A", "B"]).isEmpty, "appends accumulate, no fight")
        check(run([mod("A", ["armor": "3"]), mod("B", ["armor": "5"], req: ["a_main"])], on: ["A", "B"]).isEmpty, "B depends on A: B wins by design")
        check(run([mod("A", ["armor": "3"]), mod("B", ["armor": "5"]), ("C", [pbo("C", "c", patches: [patch("c_main", req: ["a_main", "b_main"])], classes: [cls("cfgweapons/arifle_mx_f", nil, props: ["armor": "4"])])])],
                  on: ["A", "B", "C"]).isEmpty, "a compat mod depending on both settles it")
        check(run([mod("A", ["armor": "3"]), mod("B", ["armor": "5"])], on: ["A"]).isEmpty, "one side disabled: nothing")
        check(run([mod("A", ["armor": "3"], skip: true, extra: []), mod("B", ["armor": "5"])], on: ["A", "B"]).count == 1, "skip flag alone with satisfied deps keeps the fight")
        check(run([mod("A", ["armor": "3"], req: ["missing_x"], skip: true), mod("B", ["armor": "5"])], on: ["A", "B"]).isEmpty, "a skipped PBO's classes do not exist")
        check(run([mod("A", ["armor": "3"]), mod("B", ["armor": "5"])].map { m in (m.0, m.1) }, on: ["A", "B"]).count == 1, "repeatable")
        // A class that only A and B define is a name clash, not a fight over something that existed.
        check(run([mod("A", ["armor": "3"], path: "cfgweapons/new_x"), mod("B", ["armor": "5"], path: "cfgweapons/new_x")], on: ["A", "B"]).isEmpty, "new class defined by both is not a pre-existing class")
        // ... but a class from a mod both build on is.
        let base = ("L", [pbo("L", "l", patches: [patch("l_main")], classes: [cls("cfgweapons/lib_x", nil, props: ["armor": "1"])])])
        f = run([base, mod("A", ["armor": "3"], req: ["l_main"], path: "cfgweapons/lib_x"), mod("B", ["armor": "5"], req: ["l_main"], path: "cfgweapons/lib_x")], on: ["L", "A", "B"])
        check(f.count == 1, "both patch L's class: \(f.map(\.title))")
        // Numbers written differently are the same number.
        check(run([mod("A", ["armor": "\"4.0f\""]), mod("B", ["armor": "4"])], on: ["A", "B"]).isEmpty, "4.0f and 4 agree")
        // Cosmetic-only or tiny differences stay below the bar; many significant ones do not.
        check(run([mod("A", ["picture": "\"a\"", "icon": "\"a\"", "flag": "\"a\""]), mod("B", ["picture": "\"b\"", "icon": "\"b\"", "flag": "\"b\""])], on: ["A", "B"]).isEmpty, "cosmetic")
        check(run([mod("A", ["zzz": "1"]), mod("B", ["zzz": "2"])], on: ["A", "B"]).isEmpty, "a single minor setting is below the bar")
        f = run([mod("A", ["zzz": "1", "yyy": "1", "xxx": "1"]), mod("B", ["zzz": "2", "yyy": "2", "xxx": "2"])], on: ["A", "B"])
        check(f.count == 1 && f[0].severity == .info, "three minor settings: informational")
        f = run([mod("A", ["armor": "1", "mass": "1", "scope": "1", "hit": "1"]), mod("B", ["armor": "2", "mass": "2", "scope": "2", "hit": "2"])], on: ["A", "B"])
        check(f.count == 1 && f[0].severity == .warning, "four significant settings: warning")
        // One outlier against many keepers is one finding about the outlier.
        let keepers = ["K1", "K2", "K3"].map { mod($0, ["armor": "3"]) }
        f = run([mod("O", ["armor": "9"])] + keepers, on: ["O", "K1", "K2", "K3"])
        check(f.count == 1 && f[0].title.contains("O sets") && f[0].modPaths.count == 4, "outlier collapsed: \(f.map(\.title))")
    }

    // MARK: Duplicates and prefixes

    static func duplicates() {
        let (idx, names) = library(baseVanilla, [
            ("Whole", [pbo("Whole", "x", prefix: "p\\x", size: 500, patches: [patch("x_main")]), pbo("Whole", "y", prefix: "p\\y", size: 600, patches: [patch("y_main")])]),
            ("Part", [pbo("Part", "x", prefix: "p\\x", size: 500, patches: [patch("x_main")])]),
            ("Fork", [pbo("Fork", "x", prefix: "p\\x", size: 520, patches: [patch("x_main")])]),
            ("Other", [pbo("Other", "o", prefix: "q\\o", size: 100, patches: [patch("o_main")])]),
            ("Clash", [pbo("Clash", "c", prefix: "q\\o", size: 120, patches: [patch("c_main")])]),
        ])
        let ctx = ConflictContext(index: idx, names: names)
        var f = findings(ctx, ["Whole", "Part"], .duplicateAddon)
        check(f.count == 1 && f[0].suggestedDisable == ["/lib/Part"], "identical contained copy: disable the part, got \(f.map { ($0.title, $0.suggestedDisable) })")
        f = findings(ctx, ["Whole", "Fork"], .duplicateAddon)
        check(f.count == 1 && f[0].suggestedDisable.isEmpty && f[0].detail.contains("differ"), "different versions: no suggestion, got \(f.map(\.detail))")
        check(findings(ctx, ["Whole", "Part"], .prefixCollision).isEmpty, "the prefix clash is explained by the duplicate")
        f = findings(ctx, ["Other", "Clash"], .prefixCollision)
        check(f.count == 1 && f[0].severity == .warning, "different PBOs under one prefix: \(f.map(\.title))")
        check(findings(ctx, ["Other"], .prefixCollision).isEmpty && findings(ctx, ["Whole"], .duplicateAddon).isEmpty, "single mods are fine")
        let (idx2, n2) = library(baseVanilla, [("W", [pbo("W", "x", patches: [patch("x_main")])]), ("P1", [pbo("P1", "x", patches: [patch("x_main")])]), ("P2", [pbo("P2", "x", patches: [patch("x_main")])])])
        // Three copies of one addon: both are contained in nothing; they are equal sets, reported pairwise.
        let g = findings(ConflictContext(index: idx2, names: n2), ["W", "P1", "P2"], .duplicateAddon)
        check(g.count == 3 && g.allSatisfy { $0.suggestedDisable.isEmpty }, "equal copies are reported pairwise without picking a loser: \(g.map(\.title))")
    }

    // MARK: __has_include

    static func conditional() {
        // A PBO that required another mod's addon only when that mod's files exist when it was indexed.
        let (idx, names) = library(baseVanilla, [
            ("A", [pbo("A", "a", patches: [patch("a_main", req: ["b_main"])], classes: [cls("cfgvehicles/a_car", "b_base")], probes: ["b\\addons\\main\\config.bin": true])]),
            ("B", [pbo("B", "b", prefix: "b\\addons\\main", patches: [patch("b_main")], classes: [cls("cfgvehicles/b_base", "car")])]),
            ("C", [pbo("C", "c", patches: [patch("c_main", req: ["b_main"])])]),
        ])
        let ctx = ConflictContext(index: idx, names: names)
        check(findings(ctx, ["A"]).isEmpty, "with B disabled the conditional requirement and classes do not exist: \(findings(ctx, ["A"]).map(\.title))")
        check(findings(ctx, ["A", "B"]).isEmpty, "with B enabled all is satisfied")
        check(findings(ctx, ["C"], .missingDependency).count == 1, "an unconditional requirement is still reported")
    }

    // MARK: General

    static func general() {
        let (idx, names) = library(baseVanilla, [
            ("A", [pbo("A", "a", patches: [patch("a_main", req: ["b_main"])])]),
            ("B", [pbo("B", "b", patches: [patch("b_main")])]),
        ])
        let ctx = ConflictContext(index: idx, names: names)
        check(ctx.analyze(enabled: []).isEmpty, "empty playset")
        check(ctx.analyze(enabled: ["/nope"]).isEmpty, "unknown path ignored")
        let once = findings(ctx, ["A"]), twice = ctx.analyze(enabled: ["/lib/A", "/lib/A", "/nope"])
        check(once == twice, "duplicates and unknown paths do not change the result")
        check(findings(ctx, ["A", "B"]).isEmpty, "complete playset is clean")
        check(once.first?.title == "A needs B, which is turned off", "display names are used: \(once.first?.title ?? "")")
        let ctx2 = ConflictContext(index: idx)
        check(ctx2.analyze(enabled: ["/lib/A"]).first?.title == "A needs B, which is turned off", "folder name is the fallback display name")
        check(ConflictContext(index: GameIndex()).analyze(enabled: ["/x"]).isEmpty, "empty library")
    }
}
