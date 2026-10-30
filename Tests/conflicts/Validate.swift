// Runs the analysis on realistic playsets of the real library and prints what it finds, with timings.
import Foundation

enum Validate {
    static func ids(_ index: GameIndex, _ names: [String: String], where match: (String, String) -> Bool) -> [String] {
        index.modOrder.filter { match(URL(fileURLWithPath: $0).lastPathComponent, names[$0] ?? "") }
    }

    static func subsets(_ index: GameIndex, _ names: [String: String]) -> [(String, [String])] {
        let core = ids(index, names) { id, _ in id == "450814997" }
        func byID(_ list: [String]) -> [String] { ids(index, names) { id, _ in list.contains(id) } }
        let ai = ids(index, names) { _, n in ["LAMBS", "VCOM", "bCombat", "ASR AI"].contains { n.localizedCaseInsensitiveContains($0) } }
        var random: [(String, [String])] = []
        for seed in [1, 2, 3] {
            var g = SplitMix(seed: UInt64(seed) &* 0x9E37_79B9)
            random.append(("random 40 (seed \(seed))", Array(index.modOrder.shuffled(using: &g).prefix(40))))
        }
        return [
            ("everything (\(index.modOrder.count))", index.modOrder),
            ("CBA + ACE", byID(["450814997", "463939057"])),
            ("RHS family (+CBA)", core + byID(["843425103", "843577117", "843593391", "843632231"])),
            ("CUP family (+CBA)", core + ids(index, names) { _, n in n.hasPrefix("CUP ") }),
            ("AI behaviour mods", ai),
            ("AI behaviour + CBA + ACE", ai + byID(["450814997", "463939057"])),
        ] + random
    }

    struct SplitMix: RandomNumberGenerator {
        var s: UInt64
        init(seed: UInt64) { s = seed }
        mutating func next() -> UInt64 {
            s &+= 0x9E37_79B9_7F4A_7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static func run() {
        let (index, names) = Lib.load()
        let t0 = Date()
        let ctx = ConflictContext(index: index, names: names)
        print(String(format: "ConflictContext init: %.2f s for %d mods", Date().timeIntervalSince(t0), index.modOrder.count))
        let env = ProcessInfo.processInfo.environment
        let verbose = env["VERBOSE"] != nil
        for (label, set) in subsets(index, names) {
            var best = 1e9
            var f: [ConflictFinding] = []
            for _ in 0..<7 { let t = Date(); f = ctx.analyze(enabled: set); best = min(best, Date().timeIntervalSince(t)) }
            print(String(format: "\n== %@: %d mods, analyze %.1f ms, %d findings", label, set.count, best * 1000, f.count))
            var counts: [String: [String: Int]] = [:]
            for x in f { counts[x.kind.rawValue, default: [:]]["\(x.severity)", default: 0] += 1 }
            for (k, v) in counts.sorted(by: { $0.key < $1.key }) { print("   \(k): " + v.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")) }
            if verbose || label.hasPrefix("CBA") || label.hasPrefix("AI") {
                for x in f where verbose || x.severity != .info {
                    print("   [\(x.kind.rawValue)/\(x.severity) \(x.confidence)] \(x.title)")
                    for e in x.evidence.prefix(verbose ? 3 : 2) { print("        - \(e.prefix(200))") }
                }
            }
        }
    }
}
