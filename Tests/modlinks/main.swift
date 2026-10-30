import Foundation
// Checks that a DLL line under Kitbag's !Kitbag/<n> links is attributed to the real mod folder.
let real = "/Users/test/Library/Application Support/Steam/steamapps/workshop/content/107410/463939057"
let other = "/Users/test/Library/Application Support/Steam/steamapps/workshop/content/107410/450814997"
let text = """
[thread 00000001][I][100]: Log system initialised
[thread 00000002][I][2000]: DLL LOADING: C:\\Users\\test\\Library\\Application Support\\Steam\\steamapps\\common\\Arma 3\\\\!Kitbag\\12\\ace_advanced_ballistics_x64.dll loaded (fully bound) at 0x10000-0x20000 (sized 65536 (0x10000) bytes)
[thread 00000002][I][2001]: DLL LOADING: !Kitbag\\1\\other_x64.dll loaded (fully bound) at 0x30000-0x40000 (sized 65536 (0x10000) bytes)
"""
let r = GameLog.parse(text, modFolders: [real, other], aliases: ["!Kitbag/12": real, "!Kitbag/1": other])
let owners = Dictionary(r.extensionLoads.map { ($0.dll, $0.modPath) }, uniquingKeysWith: { a, _ in a })
var failed = 0
for (dll, want) in [("ace_advanced_ballistics_x64.dll", real), ("other_x64.dll", other)] {
    let ok = owners[dll] == want
    print((ok ? "  ok   " : "  FAIL ") + "\(dll) -> \(owners[dll].flatMap { $0 } ?? "nil")")
    if !ok { failed += 1 }
}
print(failed == 0 ? "modlinks: all checks passed" : "modlinks: \(failed) check(s) failed")
exit(failed == 0 ? 0 : 1)
