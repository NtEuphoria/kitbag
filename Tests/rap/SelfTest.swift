// Hand-built inputs: every entry/value type round-trips, every malformed shape throws.
import Foundation

enum SelfTest {
    static var failures = 0, checks = 0

    static func check(_ ok: Bool, _ what: String, line: Int = #line) {
        checks += 1
        if !ok { failures += 1; print("FAIL [line \(line)] \(what)") }
    }

    static func expectThrow(_ data: Data, _ what: String, contains: String? = nil, line: Int = #line) {
        do {
            _ = try RapParser.parse(data)
            check(false, "\(what): parsed, expected an error", line: line)
        } catch ParseError.format(let m) {
            check(contains.map { m.contains($0) } ?? true, "\(what): wrong error \"\(m)\"", line: line)
        } catch {
            check(contains == nil, "\(what): wrong error \(error)", line: line)
        }
    }

    static func run() {
        roundTrip()
        malformed()
        widening()
        print(failures == 0 ? "selftest OK (\(checks) checks)" : "selftest FAILED \(failures)/\(checks)")
        if failures > 0 { exit(1) }
    }

    static func roundTrip() {
        let data = RapWriter.build([
            .cls("CfgPatches", [
                .cls("my_addon", [
                    .arr("units", []),
                    .arr("requiredAddons", [.s("A3_Data_F"), .s("cba_main")]),
                    .f32("requiredVersion", 2.14),
                    .i32("skipWhenMissingDependencies", 1),
                ]),
                .ext("other_addon"),
            ]),
            .cls("CfgVehicles", [
                .ext("Car_F"),
                .cls("My_Car", parent: "Car_F", [
                    .str("displayName", "Mÿ Car"),
                    .variable("access", "ReadAndWrite"),
                    .i32("scope", -2),
                    .i64("big", 1 << 40),
                    .f32("mass", 0.1),
                    .arr("nested", [.i(1), .f(0.5), .s("x"), .v("y"), .l(-5), .a([.a([.i(7)]), .a([])])]),
                    .append("magazines", [.s("mag_a")]),
                    .append("magazines", [.s("mag_b")]),
                    .del("OldTurret"),
                    .cls("Turrets", [.cls("MainTurret", [.cls("Turrets", [])])]),
                ]),
            ]),
        ], enums: [("destructno", 0), ("destructbuilding", 1)])

        guard let root = try? RapParser.parse(data) else { return check(false, "valid file failed to parse") }
        check(RapParser.isRapified(data), "isRapified on a valid file")
        check(root.name == "" && root.parent == nil && root.children.count == 2, "root shape")

        let patches = PatchInfo.extract(from: root)
        check(patches.count == 1, "external CfgPatches entry is not an addon")
        check(patches.first == PatchInfo(name: "my_addon", requiredAddons: ["a3_data_f", "cba_main"],
                                         requiredVersion: 2.14, skipWhenMissingDependencies: true),
              "PatchInfo: \(String(describing: patches.first))")

        guard let car = root.child("cfgvehicles")?.child("my_car") else { return check(false, "My_Car missing") }
        check(root.child("CfgVehicles")?.child("Car_F")?.isExternal == true, "external class")
        check(car.parent == "Car_F" && !car.isExternal, "parent name as written")
        check(car.properties["displayname"] == .string("Mÿ Car"), "UTF-8 string")
        check(car.properties["access"] == .string("ReadAndWrite"), "variable subtype → string")
        check(car.properties["scope"] == .number(-2), "negative int32")
        check(car.properties["big"] == .number(Double(1 << 40)), "int64")
        check(car.properties["mass"] == .number(0.1), "float widened to 0.1, got \(String(describing: car.properties["mass"]))")
        check(car.properties["nested"] == .array([.number(1), .number(0.5), .string("x"), .string("y"), .number(-5),
                                                  .array([.array([.number(7)]), .array([])])]), "nested array")
        check(car.appends["magazines"] == [.string("mag_a"), .string("mag_b")], "repeated += accumulates")
        check(car.properties["magazines"] == nil, "+= is not an assignment")
        check(car.deletes == ["OldTurret"], "delete")
        check(car.child("Turrets")?.child("MainTurret")?.child("Turrets")?.children.isEmpty == true, "deep classes")

        let summary = ConfigSummary.make(from: root, includeProperties: true)
        check(summary.classes.contains { $0.path == "cfgvehicles/my_car" && $0.props["magazines"] == "+={\"mag_a\",\"mag_b\"}" },
              "ConfigSummary sees appends")

        // A slice with a non-zero startIndex parses the same.
        var padded = Data([1, 2, 3]); padded.append(data)
        check((try? RapParser.parse(padded.dropFirst(3)))?.children.count == 2, "Data slice")

        // Every truncation of a valid file throws or (only past the last body) still parses: never traps.
        let lastBody = data.count - 4 - 2 * 5 - "destructno".count - "destructbuilding".count
        for n in 0..<data.count {
            let cut = data.prefix(n)
            if (try? RapParser.parse(cut)) != nil { check(n >= lastBody, "truncated to \(n) bytes still parsed") }
        }
    }

    static func malformed() {
        expectThrow(Data(), "empty", contains: "not a rapified")
        expectThrow(Data("class CfgPatches {};".utf8), "text config", contains: "not a rapified")
        expectThrow(Data([0, 0x72, 0x61, 0x50, 0, 0, 0, 0, 8, 0, 0, 0, 16, 0, 0, 0]), "header only")
        check(!RapParser.isRapified(Data([0, 0x72, 0x61, 0x50])), "4-byte magic alone is not a config")

        // Cycle: a child body pointing back at the root body.
        var w = RapWriter(); w.buf = [0, 0x72, 0x61, 0x50]; w.u32(0); w.u32(8); w.u32(0)
        w.cstr(""); w.cint(1); w.u8(0); w.cstr("Loop"); w.u32(16)
        expectThrow(Data(w.buf), "cycle to root", contains: "reuses")

        // Two classes sharing one body.
        w = RapWriter(); w.buf = [0, 0x72, 0x61, 0x50]; w.u32(0); w.u32(8); w.u32(0)
        w.cstr(""); w.cint(2); w.u8(0); w.cstr("A"); w.u32(32); w.u8(0); w.cstr("B"); w.u32(32)
        w.cstr(""); w.cint(0)
        check(w.buf.count == 34, "shared-body fixture layout (\(w.buf.count))")
        expectThrow(Data(w.buf), "shared body", contains: "reuses")

        // Overlapping bodies: B's body starts one byte into A's, which re-reads A's bytes.
        w = RapWriter(); w.buf = [0, 0x72, 0x61, 0x50]; w.u32(0); w.u32(8); w.u32(0)
        w.cstr(""); w.cint(2); w.u8(0); w.cstr("A"); w.u32(32); w.u8(0); w.cstr("B"); w.u32(33)
        w.cstr(""); w.cint(0); w.cstr(""); w.cint(0)
        expectThrow(Data(w.buf), "body offset into another body", contains: "overlap")

        // Body offsets outside the file / inside the header.
        for bad: UInt32 in [0, 4, 15, 0xFFFF_FFFF, 1000] {
            w = RapWriter(); w.buf = [0, 0x72, 0x61, 0x50]; w.u32(0); w.u32(8); w.u32(0)
            w.cstr(""); w.cint(1); w.u8(0); w.cstr("A"); w.u32(bad)
            expectThrow(Data(w.buf), "body offset \(bad)", contains: "outside the file")
        }

        // Nesting caps.
        var deep: [TEntry] = []
        for k in 0..<(RapParser.maxClassDepth + 5) { deep = [.cls("C\(k)", deep)] }
        expectThrow(RapWriter.build(deep), "class nesting", contains: "nested deeper")
        var ok: [TEntry] = []
        for k in 0..<RapParser.maxClassDepth { ok = [.cls("C\(k)", ok)] }
        check((try? RapParser.parse(RapWriter.build(ok))) != nil, "nesting at the cap parses")
        var arr: [TElem] = []
        for _ in 0..<(RapParser.maxArrayDepth + 5) { arr = [.a(arr)] }
        expectThrow(RapWriter.build([.arr("x", arr)]), "array nesting", contains: "nested deeper")

        // Counts far larger than the data.
        w = RapWriter(); w.buf = [0, 0x72, 0x61, 0x50]; w.u32(0); w.u32(8); w.u32(0)
        w.cstr(""); w.cint(1 << 34); w.u8(1); w.u8(2); w.cstr("x"); w.u32(1)
        expectThrow(Data(w.buf), "huge entry count")
        w = RapWriter(); w.buf = [0, 0x72, 0x61, 0x50]; w.u32(0); w.u32(8); w.u32(0)
        w.cstr(""); w.cint(1); w.u8(2); w.cstr("x"); w.cint(1 << 34)
        expectThrow(Data(w.buf), "huge array count")
        w = RapWriter(); w.buf = [0, 0x72, 0x61, 0x50]; w.u32(0); w.u32(8); w.u32(0)
        w.cstr(""); w.buf += [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]
        expectThrow(Data(w.buf), "compressed int too long", contains: "too long")

        // Unknown codes and unterminated strings.
        w = RapWriter(); w.buf = [0, 0x72, 0x61, 0x50]; w.u32(0); w.u32(8); w.u32(0)
        w.cstr(""); w.cint(1); w.u8(9); w.cstr("x")
        expectThrow(Data(w.buf), "entry type 9", contains: "unknown entry type 9")
        for sub: UInt8 in [3, 5, 7, 200] {
            w = RapWriter(); w.buf = [0, 0x72, 0x61, 0x50]; w.u32(0); w.u32(8); w.u32(0)
            w.cstr(""); w.cint(1); w.u8(1); w.u8(sub); w.cstr("x"); w.u32(0)
            expectThrow(Data(w.buf), "value subtype \(sub)", contains: "unknown value type")
        }
        let odd = try? RapParser.parse(RapWriter.build([.append("x", flags: 2, [.s("a")]), .i32("after", 3)]))
        check(odd?.appends.isEmpty == true && odd?.properties["after"] == .number(3), "unknown += flags: entry skipped, rest parsed")
        w = RapWriter(); w.buf = [0, 0x72, 0x61, 0x50]; w.u32(0); w.u32(8); w.u32(0)
        w.cstr(""); w.cint(1); w.u8(1); w.u8(0); w.cstr("x"); w.buf += Array("no terminator".utf8)
        expectThrow(Data(w.buf), "unterminated string")
    }

    static func widening() {
        for (f, d) in [(Float(0.1), 0.1), (2.14, 2.14), (1.0, 1.0), (-0.25, -0.25), (1e-5, 1e-5), (0.333333, 0.333333),
                       (123.456, 123.456), (3.4e38, 3.4e38), (1e10, 1e10), (16777216, 16777216), (16777218, 16777218), (0.0001, 0.0001)] as [(Float, Double)] {
            check(RapParser.widen(f) == d, "widen(\(f)) = \(RapParser.widen(f)), expected \(d)")
        }
        check(RapParser.widen(.nan).isNaN && RapParser.widen(.infinity) == .infinity, "non-finite floats")
        // Exhaustive-ish: every widened value must round-trip to the same float and match Float.description.
        var rng = SplitMix(seed: 42), mismatches = 0
        for _ in 0..<2_000_000 {
            let f = Float(bitPattern: UInt32(truncatingIfNeeded: rng.next()))
            guard f.isFinite else { continue }
            let w = RapParser.widen(f)
            if Float(w) != f { check(false, "widen(\(f)) does not round-trip"); break }
            if w != Double(f.description) { mismatches += 1; if mismatches < 5 { print("  widen(\(f)) = \(w), description \(f.description)") } }
        }
        check(mismatches == 0, "widen differs from Float.description on \(mismatches) random floats")
    }
}

/// Deterministic PRNG so fuzz failures are reproducible.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
