// ConfigIndexer harness.
//   run selftest                 synthetic library
//   run cold [cacheDir]          wipe the cache, index vanilla + all Workshop mods, report time / size / peak RSS
//   run warm [cacheDir]          index again from the cache
//   run verify [cacheDir]        uncached build vs cache-loaded build, deep comparison
//   run report [cacheDir]        census of the index and every diagnostic
//   run research                 evidence for the config.cpp / config.bin and nested-config rules
//   run conditional [cacheDir]   __has_include playset behaviour on the real library
//   run incremental [cacheDir]   damaged cache file, then a changed library, on the real library
//   run lock                     record the parser sources for the parserVersion check (after bumping the version)
// Build: sh Tests/indexer/build.sh
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
switch args.first ?? "selftest" {
case "selftest": exit(SelfTest.run() ? 0 : 1)
case "cold": Real.cold(args.dropFirst().first)
case "warm": Real.warm(args.dropFirst().first)
case "verify": Real.verify(args.dropFirst().first)
case "report": Real.report(args.dropFirst().first)
case "research": Research.run()
case "conditional": Real.conditional(args.dropFirst().first)
case "lock": ParserLock.write()
case "incremental": Real.incremental(args.dropFirst().first)
default: print("usage: run selftest | cold | warm | verify | report | research | conditional | lock [cacheDir]")
}
