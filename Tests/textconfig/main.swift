// Text-config harness: `run selftest [scratchDir]`, `run conformance <ArmaPreprocessorTestCases dir>`,
// `run corpus`, `run dump <virtual path of a config.cpp or include>`, `run probe <virtual path> [bytes]`, `run fuzz [n]`.
// Build: swiftc -O -swift-version 5 Sources/PBOArchive.swift Sources/ConfigModel.swift \
//          Sources/ConfigPreprocessor.swift Sources/TextConfigParser.swift Sources/RapParser.swift \
//          Tests/textconfig/main.swift Tests/textconfig/SelfTest.swift Tests/textconfig/Conformance.swift \
//          Tests/textconfig/Corpus.swift Tests/textconfig/V1.swift Tests/textconfig/Probe.swift Tests/textconfig/CrossCheck.swift Tests/textconfig/Fuzz.swift -o Tests/textconfig/run
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
switch args.first ?? "selftest" {
case "selftest":
    SelfTest.run(scratch: URL(fileURLWithPath: args.count > 1 ? args[1] : NSTemporaryDirectory()))
    exit(SelfTest.failures == 0 ? 0 : 1)
case "conformance": Conformance.run(root: URL(fileURLWithPath: args[1]))
case "corpus": Corpus.run()
case "dump": Corpus.dump(args[1])
case "fuzz": Fuzz.run(perFile: args.count > 1 ? Int(args[1]) ?? 60 : 60)
case "replay": Fuzz.replay(file: args[1], path: args[2], parserOnly: args.count > 3)
case "probe": Probe.run(args[1], bytes: args.count > 2 ? Int(args[2]) ?? 600 : 600)
default: print("usage: run selftest [dir] | conformance <dir> | corpus | dump <virtual path>")
}
