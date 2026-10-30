// GameLog harness. Build with `zsh Tests/build.sh gamelog`, then run Tests/gamelog/run.
//
// Fixtures (in Tests/gamelog):
//   synthetic.eon.txt  hand-written lines in the formats documented in GameLog.swift: mod DLL loads,
//                      mod-specific dialogs, RPT text. Published with the repo.
//   steam-rosetta-90mods.eon.txt, exp1.eon.txt, exp2.eon.txt
//                      optional real logs from a local run (not published: they hold the machine's
//                      paths). Their checks are skipped when the files are absent.
// Some checks expect CBA (450814997) and ACE (463939057) in the local Workshop folder.
import Foundation

let here = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
var failures = 0
func check(_ ok: Bool, _ what: String) {
    print((ok ? "  ok   " : "  FAIL ") + what)
    if !ok { failures += 1 }
}
func fixture(_ name: String) -> String { (try? String(contentsOf: here.appendingPathComponent(name), encoding: .utf8)) ?? "" }
/// A real-log fixture that only exists on the machine that recorded it; nil (and a skip line) elsewhere.
func optionalFixture(_ name: String) -> String? {
    guard let text = try? String(contentsOf: here.appendingPathComponent(name), encoding: .utf8) else {
        print("  skipped: \(name) isn't present (real logs aren't published)")
        return nil
    }
    return text
}

let workshop = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Steam/steamapps/workshop/content/107410")
let allMods = ((try? FileManager.default.contentsOfDirectory(at: workshop, includingPropertiesForKeys: nil)) ?? [])
    .filter { Int($0.lastPathComponent) != nil }.map(\.path).sorted()
let cba = workshop.appendingPathComponent("450814997").path
let ace = workshop.appendingPathComponent("463939057").path
let alive = workshop.appendingPathComponent("620260972").path
print("library: \(allMods.count) Workshop mods")

// MARK: real excerpt — must produce no false positives

print("\n== real log: Steam-launched Rosetta session, 90 mods")
if let text = optionalFixture("steam-rosetta-90mods.eon.txt") {
    let t0 = Date()
    let r = GameLog.parse(text, modFolders: allMods)
    print(String(format: "  parsed %d records in %.0f ms", r.lineCount, Date().timeIntervalSince(t0) * 1000))
    check(r.reachedEngine, "engine executable load seen")
    check(r.extensionLoads.isEmpty, "no mod extension loads (engine DLC DLLs like contact\\biext_*.dll are not mods)")
    check(r.missingAddons.count == 1, "exactly one missing-addon dialog")
    if let m = r.missingAddons.first {
        check(m.requiredBy == "A3_Language_F_Contact" && m.addon == "A3_Data_F_Contact", "…it is Language_F_Contact needing Data_F_Contact")
        check(m.isGameAddon, "…flagged as a base-game addon, not a mod's fault")
    }
    check(r.modMissingAddons.isEmpty, "no mod-caused missing addons")
    check(r.configErrors.isEmpty && r.scriptErrors.isEmpty, "no config/script errors (the wrapper does not forward RPT text)")
    check(r.wrapperErrors.isEmpty, "no wrapper errors: \(r.wrapperErrors.map(\.line))")
    check(r.failedExtensions.isEmpty, "no failed extensions (tbb4malloc_bi.dll / EnableHugePages are known engine noise)")
    check(r.isClean, "report is clean")
    check(r.elapsedMs == 214902, "elapsed = last timestamp (\(r.elapsedMs) ms)")
    let logoLines = text.split(separator: "\n").filter { $0.contains("dtaExt\\") }
    let ids = Set(logoLines.compactMap { l -> String? in
        guard let r = l.range(of: #"arma 3\\(\d+)\\"#, options: .regularExpression) else { return nil }
        return String(l[r].dropFirst(7).dropLast())
    })
    check(r.listedMods.count == ids.count && ids.count > 80, "listedMods = \(r.listedMods.count) of \(ids.count) mod folders named in logo lookups")
    check(r.listedMods.contains(cba) && r.listedMods.contains(ace), "CBA and ACE are among the listed mods")
    check(r.lastLines.count <= GameLog.lastLineCount && !r.lastLines.isEmpty && !r.lastLines.contains { $0.contains("406d1388") },
          "lastLines is short and free of thread-name noise (\(r.lastLines.count))")
}

// MARK: real failed launches

print("\n== real logs: the two launches that died at startup")
for name in ["exp1.eon.txt", "exp2.eon.txt"] {
    guard let text = optionalFixture(name) else { continue }
    let r = GameLog.parse(text, modFolders: allMods)
    check(r.lineCount == 3 && !r.reachedEngine, "\(name): 3 lines, engine never loaded (launch failure, no mod to blame)")
    check(r.isClean && r.lastLines.count == 3, "\(name): nothing misattributed; lastLines keeps the whole log")
}

// MARK: synthetic events

print("\n== synthetic log: formats the real runs did not reach")
do {
    let owners = ["tier1_weapons": workshop.appendingPathComponent("2268351256").path]
    let prefixes = GameLog.prefixIndex(modFolders: [cba, ace, alive])
    let r = GameLog.parse(fixture("synthetic.eon.txt"), modFolders: allMods, prefixIndex: prefixes, addonOwners: owners)
    check(r.reachedEngine, "engine loaded")

    check(r.extensionLoads.count == 3, "3 mod extension entries: 2 loads + 1 failure (got \(r.extensionLoads.count))")
    let ext = Dictionary(uniqueKeysWithValues: r.extensionLoads.map { ($0.dll.lowercased(), $0) })
    check(ext["ace_x64.dll"]?.loaded == true && ext["ace_x64.dll"]?.modPath == ace, "ace_x64.dll loaded, attributed to ace by Workshop path")
    check(ext["ace_x64.dll"]?.detail.contains("no export 'RVExtensionArgs'") == true, "missing RVExtensionArgs export kept as detail only")
    check(ext["aliveclient_x64.dll"]?.loaded == true && ext["aliveclient_x64.dll"]?.modPath == alive, "aliveclient_x64.dll loaded via the game-folder symlink path")
    check(ext["broken_x64.dll"]?.loaded == false && ext["broken_x64.dll"]?.modPath == cba, "broken_x64.dll failed, attributed to CBA")
    check(r.failedExtensions.count == 1, "exactly one failed extension")
    check(r.wrapperErrors.allSatisfy { !$0.line.contains("tbb4malloc") }, "engine's own tbb4malloc_bi.dll miss is ignored")

    check(r.missingAddons.count == 3, "3 distinct missing-addon pairs, duplicates folded (got \(r.missingAddons.count))")
    let t1 = r.missingAddons.first { $0.requiredBy == "tier1_weapons" }
    check(t1?.addon == "rhsusf_main" && t1?.modPath == owners["tier1_weapons"] && t1?.isGameAddon == false, "tier1_weapons needs rhsusf_main, owner resolved from addonOwners")
    check(r.modMissingAddons.count == 2, "2 are mod-caused; the Contact one is a game addon")

    check(r.scriptErrors.count == 2, "2 script errors (got \(r.scriptErrors.count))")
    if let a = r.scriptErrors.first {
        check(a.modPath == ace && a.attribution?.hasPrefix("PBO prefix z\\ace\\addons\\common") == true, "first attributed to ACE by PBO prefix (\(a.attribution ?? "nil"))")
        check(a.line.contains("Error position") && a.line.contains("Undefined variable"), "multi-line error kept together")
    }
    check(r.scriptErrors.last?.modPath == alive && r.scriptErrors.last?.attribution == "workshop path", "second attributed to ALiVE by Workshop path in the File line")
    check(r.configErrors.count == 4, "4 config errors: 3 RPT-style (one via OutputDebugString) + 1 dialog (got \(r.configErrors.count))")
    check(r.configErrors.contains { $0.line.contains("OutputDebugString") && $0.modPath == cba }, "[OutputDebugString] text is read like game stdout")
    check(r.configErrors.contains { $0.line.contains("Updating base class") && $0.modPath == cba }, "'Updating base class … by x\\cba\\…' attributed to CBA via prefix")
    check(r.configErrors.contains { $0.line.contains("Missing ';'") }, "config parse dialog classed as a config error")
    check(!r.scriptErrors.contains { $0.line.contains("SkyKeyframer") } && !r.configErrors.contains { $0.line.contains("SkyKeyframer") }, "TBB stdout chatter ignored")

    check(r.wrapperErrors.contains { $0.line.contains("Out of memory") }, "unrelated dialog surfaced as a wrapper error")
    check(r.wrapperErrors.contains { $0.line.contains("0xc0000005") }, "real RaiseException code surfaced")
    check(!r.wrapperErrors.contains { $0.line.contains("406d1388") }, "SetThreadName exception ignored")
    check(r.wrapperErrors.contains { $0.line.contains("Unhandled exception") }, "'Unhandled exception' warning surfaced")
    check(r.startedAt != nil, "RPT-style 'Current time:' line gives a start time")
    check(r.lastLines.last?.contains("last line of the session") == true, "lastLines ends with the final line")
}

// MARK: attribution details

print("\n== attribution")
do {
    let txt = "[thread 00000009][I][5]: Game stdout/err: Error in expression <x>\n  Error position: <x>\n  Error Undefined variable in expression: _a\nFile C:\\Users\\X\\Library\\Application Support\\Steam\\steamapps\\workshop\\content\\107410\\4508149971\\a.sqf, line 1"
    let r = GameLog.parse(txt, modFolders: [cba], prefixIndex: [:])
    check(r.scriptErrors.count == 1 && r.scriptErrors[0].modPath == nil, "id 4508149971 is not mistaken for 450814997")
    let local = GameLog.parse("[thread 00000009][I][5]: Game stdout/err: Error in expression <x>\nFile c:\\users\\x\\arma 3\\@mymod\\addons\\a.sqf, line 1",
                              modFolders: ["/Users/x/Arma 3/@MyMod"], prefixIndex: [:])
    check(local.scriptErrors.first?.modPath == "/Users/x/Arma 3/@MyMod", "@MyMod attributed case-insensitively")
    let ambiguous = GameLog.parse("[thread 00000009][I][5]: Game stdout/err: Error in expression <x>\nFile z\\dup\\addons\\a\\f.sqf, line 1",
                                  modFolders: ["/m/1", "/m/2"], prefixIndex: ["z\\dup\\addons\\a": ["/m/1", "/m/2"]])
    check(ambiguous.scriptErrors.first?.modPath == nil, "a PBO prefix shipped by two mods is not attributed")
}

// MARK: robustness

print("\n== robustness")
do {
    check(GameLog.parse("", modFolders: []).isClean, "empty text")
    let junk = String(decoding: (0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) }, as: UTF8.self)
    check(GameLog.parse(junk, modFolders: allMods).lineCount == 0, "binary junk yields no records")
    check(GameLog.parse("[thread 1][W][x]: no ms\n[thread][W]\n[thread 00000001][W][5]\n[thread 00000001][W][5]: ok", modFolders: []).lineCount == 2, "truncated/odd prefixes tolerated")
    let spam = (0..<5000).map { "[thread 00000009][I][\($0)]: Game stdout/err: Warning Message: No entry 'x\($0)'." }.joined(separator: "\n")
    let r = GameLog.parse(spam, modFolders: [])
    check(r.configErrors.count == GameLog.maxEntriesPerCategory && r.droppedEntries == 5000 - GameLog.maxEntriesPerCategory, "entry cap keeps \(GameLog.maxEntriesPerCategory), counts the rest")
    if let real = optionalFixture("steam-rosetta-90mods.eon.txt") {
        let big = String(repeating: real + "\n", count: 100)
        let t0 = Date()
        let rb = GameLog.parse(big, modFolders: allMods)
        print(String(format: "  %d records (%.1f MB) in %.0f ms", rb.lineCount, Double(big.utf8.count) / 1e6, Date().timeIntervalSince(t0) * 1000))
        check(rb.missingAddons.count == 1, "repeated sessions fold into one missing-addon pair")
    }
}

// MARK: PBO prefix index on the real library

print("\n== prefix index")
do {
    let t0 = Date()
    let idx = GameLog.prefixIndex(modFolders: allMods)
    print(String(format: "  %d prefixes from %d mods in %.0f ms", idx.count, allMods.count, Date().timeIntervalSince(t0) * 1000))
    check(idx["x\\cba\\addons\\main"] == [cba], "x\\cba\\addons\\main -> CBA only")
    check(idx["z\\ace\\addons\\common"] == [ace], "z\\ace\\addons\\common -> ACE only")
    let shared = idx.filter { $0.value.count > 1 }
    print("  \(shared.count) prefixes are shipped by more than one mod (left unattributed), e.g. \(shared.keys.sorted().prefix(3).joined(separator: ", "))")
}

// MARK: archive

print("\n== archive")
do {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("gamelog-test-\(UUID().uuidString)")
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }
    let src = tmp.appendingPathComponent("eon.txt")
    GameLog.defaultURL = src
    let dir = tmp.appendingPathComponent("logs/nested")
    check(GameLog.archiveCurrentLog(to: dir) == nil, "no log -> nil")
    try "".write(to: src, atomically: true, encoding: .utf8)
    check(GameLog.archiveCurrentLog(to: dir) == nil, "empty log -> nil")
    // What every startup crash of the Apple Silicon build on macOS 27 leaves behind.
    let crashedLaunch = """
    [thread ffffffff][I][0]: Log system initialised
    [thread ffffffff][I][0]: eON_Core::init() - libICU initialised with result 0.
    [thread ffffffff][I][0]: Default allowed number of simultaneously open files in the system is 1048576.

    """
    try crashedLaunch.write(to: src, atomically: true, encoding: .utf8)
    check(GameLog.archiveCurrentLog(to: dir) == nil && GameLog.archivedLogs(in: dir).isEmpty, "3-line crashed-launch log is not archived")
    var last: URL?
    let pad = String(repeating: "x", count: GameLog.minArchiveBytes)
    for i in 0..<13 {
        try "run \(i)\n\(pad)\n".write(to: src, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_800_000_000 + Double(i) * 3600)], ofItemAtPath: src.path)
        last = GameLog.archiveCurrentLog(to: dir, keep: 10)
    }
    let kept = GameLog.archivedLogs(in: dir)
    check(kept.count == 10, "keeps 10 of 13 (\(kept.count))")
    check(kept.first?.lastPathComponent == last?.lastPathComponent && (try? String(contentsOf: kept[0], encoding: .utf8))?.hasPrefix("run 12\n") == true, "newest first, content intact")
    check(kept.last.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.hasPrefix("run 3\n") == true, "oldest kept is run 3")
    check(GameLog.archiveCurrentLog(to: dir, keep: 10) == last && GameLog.archivedLogs(in: dir).count == 10, "archiving the same log twice is a no-op")
    check(last?.lastPathComponent.hasPrefix("arma3-") == true && last?.lastPathComponent.hasSuffix(".eon.txt") == true, "name \(last?.lastPathComponent ?? "nil")")
    let loaded = GameLog.load(last!, modFolders: [])
    check(loaded?.endedAt != nil && loaded?.startedAt != nil, "load() derives dates from the file")
}

// MARK: Kitbag's "Windows-only extensions" warning against this library

print("\n== library survey: which mods trigger the v1 'Windows-only extensions' warning")
do {
    var warned = 0, withX64 = 0, only32 = 0
    var examples: [String] = []
    for m in allMods {
        let root = (try? FileManager.default.contentsOfDirectory(atPath: m)) ?? []
        let dlls = root.filter { $0.lowercased().hasSuffix(".dll") }
        let macLibs = root.contains { $0.lowercased().hasSuffix(".dylib") || $0.lowercased().hasSuffix(".so") }
        guard !dlls.isEmpty, !macLibs else { continue }
        warned += 1
        if dlls.contains(where: { $0.lowercased().hasSuffix("_x64.dll") }) { withX64 += 1 } else { only32 += 1 }
        examples.append(URL(fileURLWithPath: m).lastPathComponent + ":" + dlls.joined(separator: ","))
    }
    print("  v1 warns for \(warned) mods; \(withX64) ship a *_x64.dll the 64-bit Windows engine can load; \(only32) ship only 32-bit DLLs the x64 engine never loads; warned mods: \(examples)")
}

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
