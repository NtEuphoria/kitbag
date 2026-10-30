// RapParser harness: `run selftest`, `run fuzz [iterations]`, `run corpus [--serial]`, `run inspect <pbo> [entry]`.
// Build: swiftc -O -swift-version 5 Sources/PBOArchive.swift Sources/ConfigModel.swift Sources/RapParser.swift \
//          Tests/rap/main.swift Tests/rap/Writer.swift Tests/rap/SelfTest.swift Tests/rap/Fuzz.swift \
//          Tests/rap/Corpus.swift Tests/rap/Census.swift Tests/rap/V1.swift -o Tests/rap/run
import Foundation

/// `run bench <pbo> [entry]`: parse time and peak-memory growth for one (large) rapified entry.
func bench(_ pbo: String, _ entry: String) {
    func peakMB() -> Int { var u = rusage(); getrusage(RUSAGE_SELF, &u); return Int(u.ru_maxrss) / 1_048_576 }
    guard let a = try? PBOArchive(url: URL(fileURLWithPath: pbo)), let e = a.entry(entry), let d = a.contents(of: e) else { return print("cannot read") }
    let before = peakMB()
    var best = Double.infinity, classes = 0
    for _ in 0..<5 {
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard let root = try? RapParser.parse(d) else { return print("parse failed") }
        best = min(best, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        classes = Corpus.countClasses(root).all
    }
    print("\(d.count / 1024) KB, \(classes) classes, best of 5: \(String(format: "%.1f", best)) ms, peak RSS \(before) → \(peakMB()) MB")
}

let args = CommandLine.arguments.dropFirst()
switch args.first ?? "selftest" {
case "selftest": SelfTest.run()
case "fuzz": Fuzz.run(iterations: Int(args.dropFirst().first ?? "") ?? 200_000)
case "corpus": Corpus.run(serial: args.contains("--serial"))
case "inspect": Inspect.run(Array(args)[1], Array(args).count > 2 ? Array(args)[2] : "config.bin")
case "bench": bench(Array(args)[1], Array(args).count > 2 ? Array(args)[2] : "config.bin")
default: print("usage: run selftest | fuzz [n] | corpus [--serial] | inspect <pbo> [entry]")
}
