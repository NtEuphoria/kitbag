// Conflict-analysis harness. Modes: selftest (synthetic, offline) | stats | vanilla | probe <ids> | explain <id>
// | hist | deps | probes | alone <id> | validate | verify | addons <id> | memory | find <class> | dump <pbo>.
// Everything except selftest reads the local Workshop library.
import Foundation
let args = Array(CommandLine.arguments.dropFirst())
switch args.first ?? "help" {
case "selftest": exit(SelfTest.run() ? 0 : 1)
case "stats": Stats.run()
case "vanilla": Stats.vanilla()
case "probe": Stats.probe(Array(args.dropFirst()))
case "explain": Stats.explain(Array(args.dropFirst()))
case "hist": Stats.histogram()
case "deps": Truth.dependencies()
case "probes": Stats.probes()
case "alone": Stats.alone(Array(args.dropFirst()))
case "validate": Validate.run()
case "verify": Verify.run()
case "addons": Stats.addons(Array(args.dropFirst()))
case "memory": Stats.memory()
case "find": Stats.find(Array(args.dropFirst()))
case "dump": Inspect.dump(Array(args.dropFirst()))
default: print("usage: run selftest | stats | vanilla | probe | explain | hist | deps | probes | alone | validate | verify | addons | memory | find | dump")
}
