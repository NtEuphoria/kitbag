// Test-only helpers: a minimal PBO writer, a synthetic library on disk, and deep comparison of indexes.
import Foundation

enum TestPBO {
    /// A PBO with an optional `prefix` header and uncompressed entries (names use `\`).
    static func build(prefix: String?, _ files: [(String, Data)]) -> Data {
        var out = Data()
        func cstr(_ s: String) { out.append(contentsOf: Array(s.utf8)); out.append(0) }
        func u32(_ v: UInt32) { for k in 0..<4 { out.append(UInt8(truncatingIfNeeded: v >> (8 * k))) } }
        if let prefix {
            cstr(""); u32(PBOArchive.versMagic); u32(0); u32(0); u32(0); u32(0)
            cstr("prefix"); cstr(prefix); cstr("")
        }
        for (n, d) in files { cstr(n); u32(0); u32(UInt32(d.count)); u32(0); u32(0); u32(UInt32(d.count)) }
        cstr(""); for _ in 0..<5 { u32(0) }
        for (_, d) in files { out.append(d) }
        return out
    }

    static func write(_ url: URL, prefix: String?, _ files: [(String, String)]) {
        write(url, prefix: prefix, data: files.map { ($0.0, Data($0.1.utf8)) })
    }

    static func write(_ url: URL, prefix: String?, data files: [(String, Data)]) {
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! build(prefix: prefix, files).write(to: url)
    }

    static func patches(_ name: String, requires: [String], extra: [TEntry] = []) -> TEntry {
        .cls("CfgPatches", [.cls(name, [.arr("requiredAddons", requires.map { .s($0) }), .f32("requiredVersion", 1.0)] + extra)])
    }

    static func setMTime(_ url: URL, _ date: Date) {
        try! FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}

/// A small library with every case the indexer has to get right.
struct SyntheticLibrary {
    let root: URL
    var game: URL { root.appendingPathComponent("game") }
    var modsDir: URL { root.appendingPathComponent("mods") }
    func mod(_ n: String) -> URL { modsDir.appendingPathComponent(n) }
    func pbo(_ m: String, _ name: String) -> URL { mod(m).appendingPathComponent("addons/\(name).pbo") }
    var modFolders: [URL] { ["modA", "modB", "modC", "modD", "modE", "modF", "modG", "modH", "modI", "modJ", "modK"].map(mod) }

    static let coreDefs = "#define ADDON modd_core_macro\n"

    static func create(at root: URL) -> SyntheticLibrary {
        try? FileManager.default.removeItem(at: root)
        let lib = SyntheticLibrary(root: root)
        let g = lib.game

        // Base game: root Addons, a DLC folder, Dta, and the folders that must be skipped.
        TestPBO.write(g.appendingPathComponent("Addons/a3_base.pbo"), prefix: "a3\\base", data: [("config.bin", RapWriter.build([
            TestPBO.patches("A3_Base", requires: []),
            .cls("CfgVehicles", [.cls("All", []), .cls("AllVehicles", parent: "All", []), .cls("Car", parent: "AllVehicles", [.str("displayName", "Car")])]),
        ]))])
        TestPBO.write(g.appendingPathComponent("Expansion/Addons/a3_exp.pbo"), prefix: "a3\\exp", data: [
            ("config.bin", RapWriter.build([
                TestPBO.patches("A3_Exp", requires: ["A3_Base"]),
                .cls("CfgVehicles", [.ext("Car"), .cls("Car_F", parent: "Car", []), .ext("Ghost")]),
            ])),
            ("ui\\config.bin", RapWriter.build([TestPBO.patches("A3_Exp_Ui", requires: ["A3_Exp"])])),
        ])
        TestPBO.write(g.appendingPathComponent("Dta/bin.pbo"), prefix: "bin", data: [("config.bin", RapWriter.build([
            TestPBO.patches("A3_Bin", requires: []), .cls("CfgWorlds", [.cls("DefaultWorld", [])]),
        ]))])
        TestPBO.write(g.appendingPathComponent("123456/addons/skipped_numeric.pbo"), prefix: "s1", [("config.cpp", "class CfgPatches { class Skipped1 {}; };")])
        TestPBO.write(g.appendingPathComponent("@mod/addons/skipped_at.pbo"), prefix: "s2", [("config.cpp", "class CfgPatches { class Skipped2 {}; };")])
        TestPBO.write(g.appendingPathComponent("Thing.app/addons/skipped_app.pbo"), prefix: "s3", [("config.cpp", "class CfgPatches { class Skipped3 {}; };")])

        // modA: nested configs, an optionals PBO Arma never loads, a Windows-only extension.
        TestPBO.write(lib.pbo("modA", "main"), prefix: "x\\moda\\addons\\main", data: [
            ("config.bin", RapWriter.build([
                TestPBO.patches("modA_main", requires: ["A3_Base"]),
                .cls("CfgVehicles", [.ext("Car_F"), .cls("ModA_Car", parent: "Car_F", [.str("displayName", "A Car"), .f32("armor", 0.1), .arr("hiddenSelections", [.s("camo")])])]),
            ])),
            ("sub\\config.bin", RapWriter.build([
                TestPBO.patches("modA_sub", requires: ["modA_main"]),
                .cls("CfgVehicles", [.cls("ModA_Truck", parent: "ModA_Car", [.i32("scope", 2)]), .del("ModA_Old")]),
            ])),
            ("sub\\deep\\config.bin", RapWriter.build([.cls("CfgWeapons", [.cls("ModA_Gun", [.append("magazines", [.s("m1")])])])])),
        ])
        TestPBO.write(lib.mod("modA").appendingPathComponent("optionals/opt.pbo"), prefix: "x\\moda\\opt", [("config.cpp", "class CfgPatches { class modA_opt {}; };")])
        FileManager.default.createFile(atPath: lib.mod("modA").appendingPathComponent("moda_x64.dll").path, contents: Data())

        // modB: folders holding both config.cpp and config.bin. `both` disagrees about CfgPatches, `same` does not.
        TestPBO.write(lib.pbo("modB", "both"), prefix: "x\\modb\\addons\\both", data: [
            ("config.cpp", Data("class CfgPatches { class modB_both { requiredAddons[] = {\"A3_Base\"}; }; };\nclass CfgVehicles { class Car; class ModB_Car: Car { displayName = \"cpp\"; }; };".utf8)),
            ("config.bin", RapWriter.build([TestPBO.patches("modB_both", requires: ["A3_Base", "extra_only_in_bin"]), .cls("CfgVehicles", [.ext("Car"), .cls("ModB_Car", parent: "Car", [.str("displayName", "bin")])])])),
        ])
        TestPBO.write(lib.pbo("modB", "same"), prefix: "x\\modb\\addons\\same", data: [
            ("config.cpp", Data("class CfgPatches { class modB_same { requiredAddons[] = {\"A3_Base\"}; requiredVersion = 1.0; }; };".utf8)),
            ("config.bin", RapWriter.build([TestPBO.patches("modB_same", requires: ["A3_Base"])])),
        ])
        FileManager.default.createFile(atPath: lib.mod("modB").appendingPathComponent("b.dll").path, contents: Data())
        FileManager.default.createFile(atPath: lib.mod("modB").appendingPathComponent("b.dylib").path, contents: Data())

        // modC: text config built from macros defined in another mod's PBO, with a __has_include list.
        TestPBO.write(lib.pbo("modC", "macros"), prefix: "x\\modc\\addons\\macros", [("config.cpp", """
            #include "\\x\\modd\\addons\\core\\defs.hpp"
            class CfgPatches {
                class ADDON {
                    requiredAddons[] = { "A3_Base"
            #if __has_include("\\x\\mode\\addons\\opt\\flag.hpp")
                        , "mode_opt"
            #endif
                    };
                    requiredVersion = 1.0;
                };
            };
            class CfgVehicles { class Car_F; class ModC_Car: Car_F { displayName = "C"; scope = 2; }; };
            """)])
        TestPBO.write(lib.pbo("modD", "core"), prefix: "x\\modd\\addons\\core", [("defs.hpp", coreDefs)])
        TestPBO.write(lib.pbo("modE", "opt"), prefix: "x\\mode\\addons\\opt", data: [
            ("flag.hpp", Data("// presence is the flag\n".utf8)),
            ("config.bin", RapWriter.build([TestPBO.patches("mode_opt", requires: ["A3_Base"])])),
        ])
        // modF: no addons folder at all.
        try! FileManager.default.createDirectory(at: lib.mod("modF"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: lib.mod("modF").appendingPathComponent("readme.txt").path, contents: Data("x".utf8))
        // modG: a file that is not a PBO.
        try! FileManager.default.createDirectory(at: lib.mod("modG").appendingPathComponent("addons"), withIntermediateDirectories: true)
        try! Data("this is not a pbo".utf8).write(to: lib.pbo("modG", "broken"))
        // modH: a text config that cannot be parsed, no .bin to fall back on.
        TestPBO.write(lib.pbo("modH", "badcfg"), prefix: "x\\modh\\addons\\badcfg", [("config.cpp", "class CfgPatches { class modH_bad { requiredAddons[] = {\"A3_Base\" }; };\n")])
        // modI: a broken .cpp with a valid .bin beside it.
        TestPBO.write(lib.pbo("modI", "fallback"), prefix: "x\\modi\\addons\\fallback", data: [
            ("config.cpp", Data("class CfgPatches { class modI_fb { requiredAddons[] = {\"A3_Base\" ; };".utf8)),
            ("config.bin", RapWriter.build([TestPBO.patches("modI_fb", requires: ["A3_Base"])])),
        ])
        // modJ: a config.cpp that holds rapified data.
        TestPBO.write(lib.pbo("modJ", "rapcpp"), prefix: "x\\modj\\addons\\rapcpp", data: [
            ("config.cpp", RapWriter.build([TestPBO.patches("modJ_rap", requires: ["A3_Base"])])),
        ])
        // modK: damaged inputs. A rapified header over junk, an entry whose data runs past the end of the file, an empty PBO.
        TestPBO.write(lib.pbo("modK", "junk"), prefix: "x\\modk\\addons\\junk", data: [("config.bin", Data([0x00, 0x72, 0x61, 0x50] + [UInt8](repeating: 0xAB, count: 64)))])
        let whole = TestPBO.build(prefix: "x\\modk\\addons\\trunc", [("config.bin", RapWriter.build([TestPBO.patches("modK_trunc", requires: [])]))])
        try! FileManager.default.createDirectory(at: lib.pbo("modK", "trunc").deletingLastPathComponent(), withIntermediateDirectories: true)
        try! whole.prefix(whole.count - 20).write(to: lib.pbo("modK", "trunc"))
        TestPBO.write(lib.pbo("modK", "empty"), prefix: nil, data: [])
        return lib
    }
}

/// Differences between two indexes, empty when identical.
func diff(_ a: GameIndex, _ b: GameIndex) -> [String] {
    var out: [String] = []
    if a.vanilla.addons != b.vanilla.addons { out.append("vanilla addons") }
    if a.vanilla.addonSource != b.vanilla.addonSource { out.append("vanilla addonSource") }
    if a.vanilla.parents != b.vanilla.parents { out.append("vanilla parents") }
    if a.vanilla.externalOnly != b.vanilla.externalOnly { out.append("vanilla externalOnly") }
    if a.vanilla.pbos != b.vanilla.pbos { out.append("vanilla pbos") }
    if a.modOrder != b.modOrder { out.append("modOrder") }
    if a.libraryKey != b.libraryKey { out.append("libraryKey") }
    if Set(a.mods.keys) != Set(b.mods.keys) { out.append("mod set"); return out }
    for (k, x) in a.mods {
        let y = b.mods[k]!
        let name = (k as NSString).lastPathComponent
        if x.hasAddonsFolder != y.hasAddonsFolder { out.append("\(name) hasAddonsFolder") }
        if x.windowsOnlyExtensions != y.windowsOnlyExtensions { out.append("\(name) windowsOnlyExtensions") }
        if x.macExtensions != y.macExtensions { out.append("\(name) macExtensions") }
        if x.pbos.count != y.pbos.count { out.append("\(name) pbo count"); continue }
        for (p, q) in zip(x.pbos, y.pbos) {
            let id = "\(name)/\(p.name)"
            if p.path != q.path || p.size != q.size || p.mtime != q.mtime || p.prefix != q.prefix { out.append("\(id) header") }
            if p.hasIncludeProbes != q.hasIncludeProbes { out.append("\(id) probes") }
            if p.configFiles != q.configFiles { out.append("\(id) configFiles") }
            if p.summary.patches != q.summary.patches { out.append("\(id) patches") }
            if p.summary.classes != q.summary.classes { out.append("\(id) classes") }
            if p.summary.diagnostics != q.summary.diagnostics { out.append("\(id) diagnostics") }
        }
    }
    return out
}
