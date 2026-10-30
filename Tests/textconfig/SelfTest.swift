// Unit checks for VirtualFileSystem, ConfigPreprocessor and TextConfigParser on hand-written inputs.
import Foundation

enum SelfTest {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var checks = 0

    static func check(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        checks += 1
        if !ok { failures += 1; print("FAIL \(what) \(detail())") }
    }

    /// Whitespace-collapsed text, so checks don't depend on the blank lines directives leave behind.
    static func flat(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func run(scratch: URL) {
        let dir = scratch.appendingPathComponent("textconfig-selftest")
        try? FileManager.default.removeItem(at: dir)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // A CBA-like main addon and a mod that builds its config from it.
        let macros = """
        #define DOUBLES(var1,var2) var1##_##var2
        #define TRIPLES(var1,var2,var3) var1##_##var2##_##var3
        #define QUOTE(var1) #var1
        #define ADDON DOUBLES(PREFIX,COMPONENT)
        #define GVAR(var1) DOUBLES(ADDON,var1)
        #define QGVAR(var1) QUOTE(GVAR(var1))
        #define QQGVAR(var1) QUOTE(QGVAR(var1))
        #define PATHTOF_SYS(var1,var2,var3) \\MAINPREFIX\\var1\\SUBPREFIX\\var2\\var3
        #define PATHTOF(var1) PATHTOF_SYS(PREFIX,COMPONENT,var1)
        #define QPATHTOF(var1) QUOTE(PATHTOF(var1))
        #define REQUIRED_VERSION 2.14
        """
        try! PBOWriter.write(dir.appendingPathComponent("cba_main.pbo"), prefix: "x\\cba\\addons\\main",
                             files: [("script_macros_common.hpp", macros), ("config.cpp", "class CfgPatches { class cba_main { requiredAddons[] = {}; }; };")])
        let component = """
        #define MAINPREFIX x
        #define PREFIX mymod
        #define SUBPREFIX addons
        #define COMPONENT main
        #include "\\x\\cba\\addons\\main\\script_macros_common.hpp"
        """
        let config = #"""
        #include "script_component.hpp"
        #include "..\common\shared.hpp"
        class CfgPatches {
            class ADDON {
                name = QUOTE(ADDON);
                units[] = {};
                requiredVersion = REQUIRED_VERSION;
                requiredAddons[] = {"cba_main", SHARED_DEP
        #if __has_include("\z\ace\addons\main\script_component.hpp")
                    , "ace_main"
        #endif
        #if __has_include("\x\cba\addons\main\script_macros_common.hpp")
                    , "cba_xeh"
        #endif
                };
                author = "Someone, with ""quotes""";
                path = QPATHTOF(data\icon.paa);
                var = QGVAR(enabled);
                q = QUOTE(call QQGVAR(enabled));
                notExpanded = "ADDON";
                single = 'ADDON';
                line = __LINE__;
                file = __FILE__;
            };
        };
        """#
        try! PBOWriter.write(dir.appendingPathComponent("mymod_main.pbo"), prefix: "x\\mymod\\addons\\main",
                             files: [("script_component.hpp", component), ("config.cpp", config)])
        try! PBOWriter.write(dir.appendingPathComponent("mymod_common.pbo"), prefix: "x\\mymod\\addons\\common",
                             files: [("shared.hpp", "#define SHARED_DEP \"mymod_common\"\n")])
        // No prefix: mounted under the file name.
        try! PBOWriter.write(dir.appendingPathComponent("NoPrefix.pbo"), prefix: nil, files: [("Data\\Inc.hpp", "x = 1;")])

        let archives = ["cba_main", "mymod_main", "mymod_common", "NoPrefix"].map {
            try! PBOArchive(url: dir.appendingPathComponent("\($0).pbo"))
        }
        let vfs = VirtualFileSystem(archives: archives)

        // VFS
        check(vfs.exists("\\X\\CBA\\addons\\main\\SCRIPT_MACROS_COMMON.hpp"), "vfs case-insensitive + leading backslash")
        check(vfs.exists("/x/cba/addons/main/script_macros_common.hpp"), "vfs forward slashes")
        check(vfs.exists("x\\mymod\\addons\\main\\..\\common\\shared.hpp"), "vfs resolves ..")
        check(!vfs.exists("x\\cba\\addons\\main"), "vfs directory is not a file")
        check(vfs.read("noprefix\\data\\inc.hpp") == "x = 1;", "vfs prefix-less PBO under its file name")
        check(vfs.read("\\x\\nothing.hpp") == nil, "vfs missing file")
        check(VirtualFileSystem.decode(Data([0xEF, 0xBB, 0xBF, 0x61])) == "a", "decode strips UTF-8 BOM")
        check(VirtualFileSystem.decode(Data([0x63, 0x61, 0x66, 0xE9])) == "caf\u{E9}", "decode falls back to Latin-1")

        // Full pipeline on the CBA-style config.
        let pp = ConfigPreprocessor(vfs: vfs)
        let cfgEntry = archives[1].entry("config.cpp")!
        let r = pp.process(vfs.read("x\\mymod\\addons\\main\\config.cpp")!, path: VirtualFileSystem.path(of: cfgEntry, in: archives[1]))
        check(r.diagnostics.isEmpty, "cba config: no diagnostics", "\(r.diagnostics)")
        check(r.usedHasInclude == ["z\\ace\\addons\\main\\script_component.hpp", "x\\cba\\addons\\main\\script_macros_common.hpp"],
              "cba config: has_include list", "\(r.usedHasInclude)")
        do {
            let root = try TextConfigParser.parse(r.text)
            let patches = PatchInfo.extract(from: root)
            check(patches.map(\.name) == ["mymod_main"], "cba config: ADDON → mymod_main", "\(patches)")
            check(patches.first?.requiredAddons == ["cba_main", "mymod_common", "cba_xeh"], "cba config: requiredAddons", "\(patches)")
            check(patches.first?.requiredVersion == 2.14, "cba config: requiredVersion")
            let c = root.child("CfgPatches")!.child("mymod_main")!
            check(c.properties["name"] == .string("mymod_main"), "QUOTE(ADDON)", "\(String(describing: c.properties["name"]))")
            check(c.properties["author"] == .string("Someone, with \"quotes\""), "doubled quotes + comma in string")
            check(c.properties["path"] == .string("\\x\\mymod\\addons\\main\\data\\icon.paa"), "QPATHTOF", "\(String(describing: c.properties["path"]))")
            check(c.properties["var"] == .string("mymod_main_enabled"), "QGVAR", "\(String(describing: c.properties["var"]))")
            check(c.properties["q"] == .string("call \"mymod_main_enabled\""), "QQGVAR inside QUOTE", "\(String(describing: c.properties["q"]))")
            check(c.properties["notexpanded"] == .string("ADDON"), "no expansion inside double quotes")
            check(c.properties["single"] == .string("mymod_main"), "expansion inside single quotes", "\(String(describing: c.properties["single"]))")
            check(c.properties["line"] == .number(22), "__LINE__", "\(String(describing: c.properties["line"]))")
            check(c.properties["file"] == .string("x\\mymod\\addons\\main\\config.cpp"), "__FILE__", "\(String(describing: c.properties["file"]))")
        } catch {
            check(false, "cba config parses", "\(error)")
        }

        // Custom __has_include answer (used by callers that model a specific playset).
        let only = ConfigPreprocessor(vfs: vfs, hasInclude: { $0.hasPrefix("z\\ace") })
        let r2 = only.process("#if __has_include(\"\\z\\ace\\addons\\main\\script_component.hpp\")\nA\n#else\nB\n#endif", path: "t.cpp")
        check(flat(r2.text) == "A", "hasInclude closure", r2.text)
        let rel = pp.process("#if __has_include(\"x\\cba\\addons\\main\\script_macros_common.hpp\")\nA\n#else\nB\n#endif", path: "t.cpp")
        check(flat(rel.text) == "B", "__has_include without leading backslash is false", rel.text)

        func pre(_ s: String, path: String = "a\\b\\t.cpp") -> PreprocessResult { pp.process(s, path: path) }
        func expect(_ src: String, _ want: String, _ what: String) {
            let got = pre(src)
            check(flat(got.text) == want, what, "got «\(flat(got.text))» want «\(want)» diags \(got.diagnostics)")
        }
        expect("#define W world\na = \"hello W\"; b = 'hello W';", "a = \"hello W\"; b = 'hello world';", "strings")
        expect("#define F(a,b) [a|b]\nF((1,2),\"x,y\")", "[(12)|\"xy\"]", "args: parens and quotes protect commas, which are dropped")
        expect("#ifdef __ARMA__\nA\n#endif tail", "A tail", "text after #endif is kept")
        expect("#define ARR_2(a,b) a,b\n#define QUOTE(x) #x\nQUOTE([ARR_2(_a,_b)] call f)", "\"[_a,_b] call f\"", "nested macro call keeps its commas")
        expect("#define A(a) -a-\n#define B Test A(test(and, some more))\nB", "Test -test(and some more)-", "plain nested parens drop commas")
        let brackets = pre("#define F(a) <a>\nF([1,2])")   // an error in Arma; kept whole here, with a diagnostic
        check(brackets.diagnostics.contains { $0.hasPrefix("macro argument count") }, "args: brackets do not protect commas", "\(brackets.diagnostics)")
        expect("#define FOO 123\n#define Q(x) #x\nQ(FOO) Q(bar)", "\"123\" \"bar\"", "stringize expands argument first")
        expect("#define GLUE(a,b) a##b\n#define FOO 123\n#define BAR 456\nGLUE(FOO,BAR) GLUE(x,y)", "123456 xy", "token pasting")
        expect("#define M(a) \\\n  first a \\\n  second\nM(1)", "first 1 second", "multi-line continuation")
        expect("#define ONE foo\n#define TWO(ONE) ONE\nTWO(bar)", "bar", "parameter shadows macro")
        expect("#define A B\n#define B A\nA B", "A B", "mutual recursion stops")
        expect("#define X X+1\nX", "X+1", "self reference stops")
        expect("#define F(x) x\nF(F(F(1)))", "1", "nested calls")
        expect("#define E()  empty\nE() E", "empty E", "zero-arg macro, bare name not expanded")
        expect("#define M  test\nM", "test", "spaces before body swallowed")
        expect("#define MACRO Test #123\nMACRO", "Test 123", "# before non-name dropped")
        expect("#define V(a,...) a|__VA_ARGS__\nV(1,2,3)", "1|2,3", "variadic")
        expect("#define G(a) pre_##a##_post\nG(mid)", "pre_mid_post", "pasting inside words")
        expect("#define P(a) \\some\\a\\path\nP(x)", "\\some\\x\\path", "parameters between backslashes")
        expect("#define M(a) a\nM(  spaced  )", "spaced", "argument whitespace")
        expect("a = 1; // c\n/* multi\nline */ b = \"//not a comment\";", "a = 1; b = \"//not a comment\";", "comments")
        expect("#ifdef NOPE\nA\n#ifdef NOPE2\nB\n#else\nC\n#endif\n#else\nD\n#endif", "D", "nested ifdef")
        expect("#define YES\n#ifndef YES\nA\n#else\nB\n#endif", "B", "ifndef/else")
        expect("#if __GAME_VER_MAJ__ >= 2\nA\n#endif\n#if __A3_EXPERIMENTAL__\nB\n#endif", "A", "#if comparison, undefined name is 0")
        expect("#define V 3\n#if defined(V) && V > 2 || 0\nA\n#elif 1\nB\n#endif", "A", "#if defined/&&/||")
        expect("#if 0\nA\n#elif 1\nB\n#else\nC\n#endif", "B", "#elif")
        expect("#undef NOT_DEFINED\n#define Z 1\n#undef Z\nZ", "Z", "#undef")
        expect("#define S(x) x\nS(a\n)", "a", "call spanning lines")
        expect("a=__LINE__;\n\nb=__LINE__;", "a=1; b=3;", "__LINE__ counts lines")
        expect("#define L __LINE__\nx\n\\\ny=L;", "x y=3;", "__LINE__ after continuation")
        expect("#define T(n) class n {};\nT(Foo) T(Bar)", "class Foo {}; class Bar {};", "class macro")

        // Diagnostics and limits.
        let missing = pre("#include \"nothere.hpp\"\nA")
        check(missing.diagnostics.contains { $0.hasPrefix("unresolved include: nothere.hpp") }, "unresolved include diag", "\(missing.diagnostics)")
        let unbalanced = pre("#ifdef X\nA")
        check(unbalanced.diagnostics.contains { $0.hasPrefix("unbalanced #if") }, "unterminated #if diag")
        let stray = pre("#endif\nA")
        check(stray.diagnostics.contains { $0.hasPrefix("unbalanced #if") } && flat(stray.text) == "A", "stray #endif diag")
        try! PBOWriter.write(dir.appendingPathComponent("loop.pbo"), prefix: "loop", files: [("self.hpp", "#include \"self.hpp\"\nX\n")])
        let loopVFS = VirtualFileSystem(archives: [try! PBOArchive(url: dir.appendingPathComponent("loop.pbo"))])
        let loop = ConfigPreprocessor(vfs: loopVFS).process("#include \"\\loop\\self.hpp\"", path: "t.cpp")
        check(loop.diagnostics.contains { $0.hasPrefix("include depth limit") }, "include recursion stops", "\(loop.diagnostics)")
        var bomb = "#define A0 x x\n"
        for k in 1...40 { bomb += "#define A\(k) A\(k - 1) A\(k - 1)\n" }
        let t0 = Date()
        let blown = pre(bomb + "A40")
        check(blown.diagnostics.contains { $0.hasPrefix("expansion limit") } && Date().timeIntervalSince(t0) < 20,
              "expansion blow-up stops", "\(blown.diagnostics) \(Date().timeIntervalSince(t0))s")
        let deep = pre((0..<300).map { "#define D\($0) D\($0 + 1)" }.joined(separator: "\n") + "\nD0")
        check(deep.diagnostics.contains { $0.hasPrefix("expansion depth limit") }, "deep chain stops", "\(deep.diagnostics.prefix(2))")
        let unterminated = pre("#define F(a) a\nF(1, 2")
        check(unterminated.diagnostics.contains { $0.hasPrefix("unterminated macro call") }, "unterminated call diag")

        parserTests()
        print("selftest: \(checks - failures)/\(checks) passed")
    }

    static func parserTests() {
        let src = #"""
        class CfgPatches {
            class A_Addon { units[] = {}; requiredAddons[] = {"A3_Data_F", "cba_main"}; requiredVersion = 0.1; };
            class Ext;
        };
        class Base;
        class Thing: Base {
            scope = 2; neg = -5; dec = .5; sci = 1.5e3; hex = 0x1F; nhex = -0x10;
            word = some words here;
            path = \a3\data_f\x.p3d;
            quoted = "a ""b"" c";
            single = 'it''s';
            nested[] = {1, {2, "x", {}}, word, -1e-2,};
            ev = __EVAL(1 + (2 * 3));
            evs[] = {__EVAL(safeZoneW - (5 * 2)), 3};
            __EXEC(a = 1;)
            nosemi = 4
            strnosemi = "x"
            class Inner { v = 1; }
            delete Old;
            arr[] += {"more"};
            arr[] += {"again"};
            noBrackets = {1, 2};
            ;;
            class Inner { w = 2; };
            num1 = 1e;
            t = true;
            snd[] = {"a.ogg", db+1, 1.0};
            f32 = 9.9999997e-05;
            big = 16777217;
            multi = "line one
        line two";
        };
        class Thing { extra = 1; };
        class LateParent: Base;
        """#
        do {
            let root = try TextConfigParser.parse(src)
            let p = PatchInfo.extract(from: root)
            check(p.count == 1 && p[0].name == "a_addon" && p[0].requiredAddons == ["a3_data_f", "cba_main"] && p[0].requiredVersion == 0.1,
                  "parser: patches", "\(p)")
            let t = root.child("thing")!
            check(t.name == "Thing" && t.parent == "Base" && !t.isExternal, "parser: class header")
            check(root.child("Base")!.isExternal, "parser: external class")
            check(root.children.filter { $0.name == "Thing" }.count == 1 && t.properties["extra"] == .number(1), "parser: reopened class merges")
            let want: [String: ConfigValue] = [
                "scope": .number(2), "neg": .number(-5), "dec": .number(0.5), "sci": .number(1500), "hex": .number(31), "nhex": .number(-16),
                "word": .string("some words here"), "path": .string("\\a3\\data_f\\x.p3d"), "quoted": .string("a \"b\" c"),
                "single": .string("it's"),
                "nested": .array([.number(1), .array([.number(2), .string("x"), .array([])]), .string("word"), .number(-0.01)]),
                "ev": .string("__EVAL(1 + (2 * 3))"), "evs": .array([.string("__EVAL(safeZoneW - (5 * 2))"), .number(3)]),
                "nosemi": .number(4), "strnosemi": .string("x"), "nobrackets": .array([.number(1), .number(2)]),
                "num1": .string("1e"), "t": .string("true"), "multi": .string("line one\nline two"),
            ]
            for (k, v) in want { check(t.properties[k] == v, "parser: \(k)", "got \(String(describing: t.properties[k]))") }
            check(t.properties["a"] == nil, "parser: __EXEC skipped")
            check(t.properties["snd"] == .array([.string("a.ogg"), .string("db+1"), .number(1)]), "parser: db+N volume stays as written", "\(String(describing: t.properties["snd"]))")
            check(t.properties["f32"] == .number(0.0001) && t.properties["big"] == .number(16777217), "parser: float32 rounding, exact integers", "\(String(describing: t.properties["f32"])) \(String(describing: t.properties["big"]))")
            check(t.deletes == ["Old"], "parser: delete")
            check(t.appends["arr"] == [.string("more"), .string("again")], "parser: += appends")
            let inner = t.child("inner")!
            check(inner.properties["v"] == .number(1) && inner.properties["w"] == .number(2), "parser: nested reopened class")
            check(root.child("LateParent")?.parent == "Base", "parser: class X: Y;")
            let e = try TextConfigParser.parse("enum { a = 1, b, c = 0x2 };\nclass CfgPatches { class X {}; };")
            check(PatchInfo.extract(from: e).map(\.name) == ["x"], "parser: enum skipped")
        } catch {
            check(false, "parser: sample parses", "\(error)")
        }
        for (bad, what) in [("class A { x = 1;", "missing }"), ("}", "stray }"), ("x = \"open", "unterminated string"),
                            ("class A { = 1; };", "missing name"), ("arr[] = {1, 2", "unterminated array"),
                            ("arr[] = {1; 2};", "semicolon inside an array")] {
            do { _ = try TextConfigParser.parse(bad); check(false, "parser rejects \(what)") }
            catch let e as TextConfigError { check(e.line >= 1, "parser error has line") }
            catch { check(false, "parser error type") }
        }
    }
}
