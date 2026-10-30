// Harness for SteamWorkshop.swift.
//   run selftest                  parser, size and update semantics, and a synthetic steamapps tree (offline)
//   run live                      API + page fetch for three items into a temp cache, then cache reuse
//   run local [steamapps]
//   run parse <dir-of-html>
//   run groundtruth <out.json> [rawPageDir] [--force]
import Foundation

let steamappsDefault = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Steam/steamapps")

var failures = 0
func check(_ cond: Bool, _ what: String) {
    if !cond { failures += 1; print("FAIL: \(what)") }
}

func selftest() {
    // KeyValues
    let doc = """
    \u{FEFF}"Root"
    {
        // comment
        "a"  "1"
        "Path"  "C:\\\\Steam\\\\x \\"q\\""
        bare  value
        "nested" [$WIN32]
        {
            "K"  "v"
            "K"  "dup"
        }
        "empty" {}
    }
    """
    let kv = KeyValues.parse(doc)
    check(kv != nil, "kv parses")
    check(kv?.node("root", "A")?.int == 1, "case-insensitive lookup")
    check(kv?.node("Root", "Path")?.string == "C:\\Steam\\x \"q\"", "escapes: \(kv?.node("Root", "Path")?.string ?? "nil")")
    check(kv?.node("Root", "bare")?.string == "value", "bare tokens")
    check(kv?.node("Root", "nested")?.children.count == 2, "duplicates kept")
    check(kv?.node("Root", "nested", "k")?.string == "v", "first duplicate wins")
    check(kv?.node("Root", "empty")?.isBlock == true && kv?.node("Root", "empty")?.children.isEmpty == true, "empty block")
    check(KeyValues.parse("\"a\" { \"b\" \"c\" ") == nil, "unterminated block rejected")
    check(KeyValues.parse("\"a\" \"b") == nil, "unterminated string rejected")
    check(KeyValues.parse("\"a\" \"b\" }") == nil, "stray brace rejected")
    check(KeyValues.parse("\"a\"") == nil, "key without value rejected")

    // Page parser on the real markup shapes
    let page = """
    <div class="workshopItemTitle">SUCK &amp; Co</div>
    <div id="sharedfiles_content_ctn" data-miniprofile-appid="107410">
    <div id="rightContents" class="responsive_local_menu"><div class="sidebar">
      <div class="panel"><div class="rightSectionTopTitle condensed">Required DLC</div>
        <div class="requiredDLCContainer"><div class="requiredDLCItem">
          <a href="https://store.steampowered.com/app/1227700"><img src="x.jpg"></a>
          <span class="requiredDLCName"><a href="https://store.steampowered.com/app/1227700">Arma 3 Creator DLC: S.O.G. Prairie Fire</a></span>
        </div></div></div>
      <div class="panel"><div class="rightSectionTopTitle condensed">Required items</div>
        <div class="requiredItemsContainer" id="RequiredItems">
          <a href="https://steamcommunity.com/workshop/filedetails/?id=2138848415" target="_blank" data-subscribed="0">
            <div class="requiredItem">  Simple UBGL &#39;Change&#x27; Kit  </div></a>
          <a href="https://steamcommunity.com/workshop/filedetails/?id=450814997" target="_blank"><div class="requiredItem">CBA_A3</div></a>
        </div></div>
      <div class="panel"><div class="title">Links</div><a href="https://steamcommunity.com/sharedfiles/filedetails/?id=1">not a requirement</a></div>
    <!-- created by -->
    </div></div></div>
    <div class="workshopItemDescription">see https://steamcommunity.com/sharedfiles/filedetails/?id=2 and store.steampowered.com/app/3</div>
    """
    let p = WorkshopPage.parse(page)
    check(p?.title == "SUCK & Co", "title \(p?.title ?? "nil")")
    check(p?.requiredItems.map(\.id) == ["2138848415", "450814997"], "required ids \(p?.requiredItems.map(\.id) ?? [])")
    check(p?.requiredItems.first?.title == "Simple UBGL 'Change' Kit", "required title \(p?.requiredItems.first?.title ?? "")")
    check(p?.requiredDLC == [.init(appID: "1227700", name: "Arma 3 Creator DLC: S.O.G. Prairie Fire")], "dlc \(p?.requiredDLC ?? [])")
    check(WorkshopPage.parse("<html><div class=\"error_ctn\"><h3>There was a problem accessing the item.</h3></div></div></html>") == nil, "error page rejected")
    check(WorkshopPage.errorMessage("<div class=\"error_ctn\"><h3>There was a problem accessing the item.</h3></div></div>") == "There was a problem accessing the item.", "error message")
    check(WorkshopPage.decodeEntities("a&amp;b&lt;&#65;&#x42;&bogus;&") == "a&b<AB&bogus;&", "entities")

    // Size semantics
    let inst = WorkshopLocalState.Installed(size: 1000, timeUpdated: 10, manifest: "5", ugcHandle: nil)
    let det = WorkshopLocalState.Details(manifest: "5", timeUpdated: 10, timeTouched: 0, subscribedBy: "1", latestTimeUpdated: 10, latestManifest: "5")
    func item(_ actual: Int64?, meta: Int64 = 0, installed: WorkshopLocalState.Installed? = inst,
              details: WorkshopLocalState.Details? = det, folder: Bool = true, downloading: Bool = false) -> WorkshopLocalState.Item {
        .init(id: "1", folder: folder ? URL(fileURLWithPath: "/tmp/x") : nil, installed: installed, details: details,
              actualSize: actual, finderMetadataSize: meta, downloading: downloading, recordsAvailable: true)
    }
    check(item(1000).sizeCheck == .match, "exact match")
    check(item(1006, meta: 6).sizeCheck == .match, ".DS_Store surplus ignored")
    check(item(999).sizeCheck == .missing(1), "deficit")
    check(item(1010, meta: 6).sizeCheck == .extra(4), "surplus beyond metadata")
    check(item(10, downloading: true).sizeCheck == .unknown, "downloading suppresses")
    check(!item(1000).needsUpdate, "up to date")
    check(item(1000, details: .init(manifest: "6", timeUpdated: 20, timeTouched: 0, subscribedBy: "1", latestTimeUpdated: 20, latestManifest: "6")).needsUpdate, "pending update (installed vs latest)")
    check(item(1000, details: .init(manifest: "5", timeUpdated: 10, timeTouched: 0, subscribedBy: "1", latestTimeUpdated: 0, latestManifest: "0")).needsUpdate == false, "unknown latest is not an update")
    check(!item(1000, details: .init(manifest: "5", timeUpdated: 10, timeTouched: 0, subscribedBy: "1", latestTimeUpdated: 30, latestManifest: "5")).needsUpdate, "metadata-only edit is not an update")
    let legacy = WorkshopLocalState.Installed(size: 1000, timeUpdated: 10, manifest: "-1", ugcHandle: "77")
    check(item(1000, installed: legacy, details: .init(manifest: "-1", timeUpdated: 10, timeTouched: 0, subscribedBy: "1", latestTimeUpdated: 30, latestManifest: "-1")).needsUpdate, "legacy update by time")
    check(WorkshopPage.parse(page.replacingOccurrences(of: "id=\"rightContents\"", with: "id=\"x\"")) == nil, "page without sidebar rejected")
    check(item(1000, installed: nil, details: nil).orphan, "orphan")
    check(!item(1000, installed: nil).orphan && item(1000, installed: nil).awaitingDownload, "subscribed, not installed")
    check(item(1000, details: nil).unsubscribed, "installed, unsubscribed")
    var info = WorkshopItemInfo(id: "1"); info.result = 1; info.manifest = "6"; info.timeUpdated = 20
    check(item(1000).isBehind(info), "behind workshop")
    info.timeUpdated = 10
    check(!item(1000).isBehind(info), "same time is not behind")

    fixtureTest()
    print(failures == 0 ? "selftest OK" : "selftest: \(failures) failure(s)")
}

/// Builds a throwaway steamapps tree covering every local state and loads it through the real code path.
func fixtureTest() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("kitbag-wsfix-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let ws = root.appendingPathComponent("workshop")
    func write(_ path: String, bytes: Int) {
        let u = ws.appendingPathComponent(path)
        try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: u.path, contents: Data(repeating: 0x41, count: bytes))
    }
    func inst(_ id: String, size: Int, manifest: String, extra: String = "") -> String {
        "\"\(id)\" { \"size\" \"\(size)\" \"timeupdated\" \"5\" \"manifest\" \"\(manifest)\" \(extra) }"
    }
    func det(_ id: String, manifest: String, latestTime: Int, latest: String, extra: String = "") -> String {
        "\"\(id)\" { \"manifest\" \"\(manifest)\" \"timeupdated\" \"5\" \"timetouched\" \"0\" \"subscribedby\" \"1\" \"latest_timeupdated\" \"\(latestTime)\" \"latest_manifest\" \"\(latest)\" \(extra) }"
    }
    let acf = """
    "AppWorkshop"
    {
        "appid" "107410"
        "NeedsUpdate" "1"
        "NeedsDownload" "0"
        "TimeLastUpdated" "1700000000"
        "WorkshopItemsInstalled"
        {
            \(inst("100", size: 10, manifest: "11"))
            \(inst("200", size: 10, manifest: "22"))
            \(inst("300", size: 10, manifest: "33"))
            \(inst("400", size: 10, manifest: "44"))
            \(inst("500", size: 10, manifest: "55"))
            \(inst("800", size: 10, manifest: "88"))
            \(inst("900", size: 10, manifest: "-1", extra: "\"ugchandle\" \"77\""))
        }
        "WorkshopItemDetails"
        {
            \(det("100", manifest: "11", latestTime: 9, latest: "12"))
            \(det("200", manifest: "22", latestTime: 5, latest: "22"))
            \(det("400", manifest: "44", latestTime: 5, latest: "44"))
            \(det("500", manifest: "55", latestTime: 5, latest: "55"))
            \(det("700", manifest: "0", latestTime: 5, latest: "77"))
            \(det("800", manifest: "88", latestTime: 99, latest: "88"))
            \(det("900", manifest: "-1", latestTime: 9, latest: "-1", extra: "\"ugchandle\" \"77\""))
        }
    }
    """
    try? fm.createDirectory(at: ws, withIntermediateDirectories: true)
    try? acf.write(to: ws.appendingPathComponent("appworkshop_107410.acf"), atomically: true, encoding: .utf8)
    write("content/107410/100/a.pbo", bytes: 10)
    write("content/107410/200/a.pbo", bytes: 5)                    // truncated
    write("content/107410/300/a.pbo", bytes: 10)                   // unsubscribed, plus Finder metadata
    write("content/107410/300/.DS_Store", bytes: 6)
    write("content/107410/400/a.pbo", bytes: 3)                    // mid-download
    write("downloads/107410/400/chunk", bytes: 1)
    write("content/107410/600/a.pbo", bytes: 10)                   // orphan
    write("content/107410/800/a.pbo", bytes: 15)                   // surplus
    write("content/107410/900/_legacy.bin", bytes: 10)
    write("content/107410/notanid/a.pbo", bytes: 1)                // not an item
    write("content/107410/.hidden/a.pbo", bytes: 1)

    let s = WorkshopService.localState(steamapps: root)
    func it(_ id: String) -> WorkshopLocalState.Item { s.items[id]! }
    check(s.acfLoaded && s.appNeedsUpdate && !s.appNeedsDownload && s.lastUpdated != nil, "app-level flags")
    check(Set(s.items.keys) == ["100", "200", "300", "400", "500", "600", "700", "800", "900"], "item ids \(s.items.keys.sorted())")
    check(it("100").needsUpdate && it("100").sizeCheck == .match && !it("100").orphan, "100: update pending")
    check(it("200").sizeCheck == .missing(5) && it("200").incomplete && it("200").sizeMismatch && !it("200").needsUpdate, "200: truncated")
    check(it("300").unsubscribed && it("300").sizeCheck == .match && it("300").finderMetadataSize == 6 && !it("300").orphan, "300: unsubscribed, .DS_Store ignored")
    check(it("400").downloading && it("400").sizeCheck == .unknown && !it("400").sizeMismatch, "400: downloading")
    check(it("500").missingFolder && it("500").sizeCheck == .unknown && it("500").tracked, "500: folder gone")
    check(it("600").orphan && !it("600").tracked && !it("600").subscribed && it("600").sizeCheck == .unknown, "600: orphan")
    check(it("700").awaitingDownload && !it("700").orphan && !it("700").needsUpdate, "700: subscribed, not installed")
    check(it("800").sizeCheck == .extra(5) && it("800").sizeMismatch && !it("800").incomplete && !it("800").needsUpdate, "800: surplus only, metadata-only edit is no update")
    check(it("900").isLegacy && it("900").needsUpdate, "900: legacy update by timestamp")
    check(s.items.values.filter(\.orphan).map(\.id) == ["600"], "only 600 is an orphan")

    let unsized = WorkshopService.localState(steamapps: root, measureSizes: false)
    check(unsized.items.values.allSatisfy { $0.sizeCheck == .unknown }, "measureSizes: false")

    // A missing or half-written .acf must not turn every folder into an orphan.
    try? "\"AppWorkshop\" { \"WorkshopItemsInstalled\" { \"1\" { \"size\" \"1\"".write(to: ws.appendingPathComponent("appworkshop_107410.acf"), atomically: true, encoding: .utf8)
    let broken = WorkshopService.localState(steamapps: root)
    check(!broken.acfLoaded && broken.items.values.allSatisfy { !$0.orphan && !$0.tracked && !$0.needsUpdate && !$0.sizeMismatch }, "unreadable .acf raises no findings")
    try? fm.removeItem(at: ws.appendingPathComponent("appworkshop_107410.acf"))
    check(!WorkshopService.localState(steamapps: root).acfLoaded, "missing .acf")
    check(!WorkshopService.localState(steamapps: root.appendingPathComponent("nope")).acfLoaded, "missing steamapps")
}

func fmtBytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

func modName(_ folder: URL?) -> String {
    guard let f = folder else { return "?" }
    for file in ["meta.cpp", "mod.cpp"] {
        if let t = try? String(contentsOf: f.appendingPathComponent(file), encoding: .utf8),
           let r = t.range(of: #"name\s*=\s*"([^"]+)""#, options: .regularExpression) {
            return String(t[r]).components(separatedBy: "\"").dropFirst().first ?? "?"
        }
    }
    return f.lastPathComponent
}

func printLocal(_ s: WorkshopLocalState) {
    let items = s.items.values.sorted { $0.id < $1.id }
    print("acf loaded: \(s.acfLoaded)  app NeedsUpdate=\(s.appNeedsUpdate) NeedsDownload=\(s.appNeedsDownload)  lastUpdated=\(s.lastUpdated.map { "\($0)" } ?? "-")")
    print("items: \(items.count)  folders: \(items.filter { $0.folder != nil }.count)  tracked: \(items.filter(\.tracked).count)  subscribed: \(items.filter(\.subscribed).count)")
    print("needsUpdate: \(items.filter(\.needsUpdate).map(\.id))")
    print("orphans: \(items.filter(\.orphan).map(\.id))")
    print("unsubscribed: \(items.filter(\.unsubscribed).map(\.id))")
    print("awaitingDownload: \(items.filter(\.awaitingDownload).map(\.id))")
    print("missingFolder: \(items.filter(\.missingFolder).map(\.id))")
    print("downloading: \(items.filter(\.downloading).map(\.id))")
    print("legacy: \(items.filter(\.isLegacy).map(\.id))")
    let mism = items.filter(\.sizeMismatch)
    print("sizeMismatch: \(mism.count)")
    for m in mism { print("  \(m.id) \(modName(m.folder)) \(m.sizeCheck) recorded=\(m.installed?.size ?? -1) actual=\(m.actualSize ?? -1)") }
    let exact = items.filter { $0.sizeCheck == .match }.count
    print("size exact matches: \(exact)/\(items.filter(\.tracked).count)")
}

struct GTRequirement: Encodable { let id: String; let title: String }

/// The dataset lists every key for every item, with null where Steam gave no answer.
struct GTLocal: Encodable {
    let tracked, subscribed, needsUpdate, orphan, unsubscribed, sizeMismatch, legacy, behindWorkshop: Bool
    let recordedSize, actualSize, installedTimeUpdated: Int64?
    let installedManifest: String?
    let sizeCheck: String

    enum CodingKeys: String, CodingKey {
        case tracked, subscribed, needsUpdate, orphan, unsubscribed, sizeMismatch, legacy, behindWorkshop
        case recordedSize, actualSize, installedTimeUpdated, installedManifest, sizeCheck
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(tracked, forKey: .tracked); try c.encode(subscribed, forKey: .subscribed)
        try c.encode(needsUpdate, forKey: .needsUpdate); try c.encode(orphan, forKey: .orphan)
        try c.encode(unsubscribed, forKey: .unsubscribed); try c.encode(sizeMismatch, forKey: .sizeMismatch)
        try c.encode(legacy, forKey: .legacy); try c.encode(behindWorkshop, forKey: .behindWorkshop)
        try c.encode(recordedSize, forKey: .recordedSize); try c.encode(actualSize, forKey: .actualSize)
        try c.encode(installedTimeUpdated, forKey: .installedTimeUpdated)
        try c.encode(installedManifest, forKey: .installedManifest); try c.encode(sizeCheck, forKey: .sizeCheck)
    }
}
struct GTItem: Encodable {
    let title: String?
    let localName: String
    let timeUpdated: Int64?
    let result: Int?
    let banned: Bool?
    let banReason: String?
    let visibility: Int?
    let manifest: String?
    let fileSize: Int64?
    let tags: [String]?
    let pageState: String?
    let requiredItems: [GTRequirement]?
    let requiredDLC: [String]?
    let requiredDLCAppIDs: [String]?
    let error: String?
    let local: GTLocal

    enum CodingKeys: String, CodingKey {
        case title, localName, timeUpdated, result, banned, banReason, visibility, manifest, fileSize, tags
        case pageState, requiredItems, requiredDLC, requiredDLCAppIDs, error, local
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title); try c.encode(localName, forKey: .localName)
        try c.encode(timeUpdated, forKey: .timeUpdated); try c.encode(result, forKey: .result)
        try c.encode(banned, forKey: .banned); try c.encode(banReason, forKey: .banReason)
        try c.encode(visibility, forKey: .visibility); try c.encode(manifest, forKey: .manifest)
        try c.encode(fileSize, forKey: .fileSize); try c.encode(tags, forKey: .tags)
        try c.encode(pageState, forKey: .pageState); try c.encode(requiredItems, forKey: .requiredItems)
        try c.encode(requiredDLC, forKey: .requiredDLC); try c.encode(requiredDLCAppIDs, forKey: .requiredDLCAppIDs)
        try c.encode(error, forKey: .error); try c.encode(local, forKey: .local)
    }
}

func sizeCheckString(_ c: WorkshopLocalState.SizeCheck) -> String {
    switch c {
    case .match: return "match"
    case .missing(let n): return "missing \(n)"
    case .extra(let n): return "extra \(n)"
    case .unknown: return "unknown"
    }
}

func groundTruth(out: URL, rawDir: URL?, force: Bool) async {
    let t0 = Date()
    let local = WorkshopService.localState(steamapps: steamappsDefault)
    print("local state in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
    let ids = local.items.keys.sorted()
    let svc = WorkshopService.shared
    await svc.setRawPageDirectory(rawDir)
    await svc.setRateLimitPatience(900)   // a library of a few hundred mods takes hours at Steam's 20-pages-per-10-minutes allowance

    var infos = await svc.details(for: ids, forceRefresh: force) { done, total in
        if done % 20 == 0 || done == total { print("  pages \(done)/\(total)  \(Int(Date().timeIntervalSince(t0))) s") }
    }
    // Retry: anything without API data or a parsed page, plus pages Steam served as unavailable
    // although the API says the item exists (could be a transient error page).
    // steamcommunity.com can rate-limit for many minutes, so be patient: up to 20 rounds, sleeping longer each time.
    var suspiciousTried = Set<String>()
    var lastFailed = Set<String>(), stagnant = 0
    for round in 1...20 {
        let failed = ids.filter { infos[$0]?.detailsFetchedAt == nil || infos[$0]?.pageState == nil || infos[$0]?.pageState == .failed }
        let suspicious = ids.filter { infos[$0]?.pageState == .unavailable && infos[$0]?.result == 1 && !suspiciousTried.contains($0) }
        if failed.isEmpty && suspicious.isEmpty { break }
        // Same failures three rounds running and none of them a rate limit: they are not going to succeed.
        let rateLimited = failed.contains { infos[$0]?.error?.contains("429") == true || infos[$0]?.error?.contains("rate") == true }
        stagnant = (Set(failed) == lastFailed && !rateLimited && suspicious.isEmpty) ? stagnant + 1 : 0
        lastFailed = Set(failed)
        if stagnant >= 3 { print("giving up on \(failed.count) persistent failures"); break }
        print("retry round \(round): \(failed.count) failed, \(suspicious.count) unavailable-but-existing  (\(Int(Date().timeIntervalSince(t0))) s)")
        suspiciousTried.formUnion(suspicious)
        try? await Task.sleep(nanoseconds: UInt64(min(60 + 30 * round, 240)) * 1_000_000_000)
        if !failed.isEmpty { infos.merge(await svc.details(for: failed, forceRefresh: false)) { _, b in b } }
        if !suspicious.isEmpty { infos.merge(await svc.details(for: suspicious, forceRefresh: true)) { _, b in b } }
    }

    var gt: [String: GTItem] = [:]
    for id in ids {
        let l = local.items[id]!
        let i = infos[id] ?? WorkshopItemInfo(id: id)
        gt[id] = GTItem(
            title: i.title, localName: modName(l.folder), timeUpdated: i.timeUpdated, result: i.result,
            banned: i.banned, banReason: i.banReason, visibility: i.visibility, manifest: i.manifest,
            fileSize: i.fileSize, tags: i.tags, pageState: i.pageState?.rawValue,
            requiredItems: i.requiredItems?.map { GTRequirement(id: $0.id, title: $0.title) },
            requiredDLC: i.requiredDLC?.map(\.name), requiredDLCAppIDs: i.requiredDLC?.map(\.appID), error: i.error,
            local: GTLocal(tracked: l.tracked, subscribed: l.subscribed, needsUpdate: l.needsUpdate, orphan: l.orphan,
                           unsubscribed: l.unsubscribed, sizeMismatch: l.sizeMismatch, legacy: l.isLegacy,
                           behindWorkshop: l.isBehind(i), recordedSize: l.installed?.size, actualSize: l.actualSize,
                           installedTimeUpdated: l.installed?.timeUpdated, installedManifest: l.installed?.manifest,
                           sizeCheck: sizeCheckString(l.sizeCheck)))
    }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! enc.encode(gt).write(to: out, options: .atomic)
    print("wrote \(out.path) (\(gt.count) items) in \(Int(Date().timeIntervalSince(t0))) s")

    // Report
    let v = gt.sorted { $0.key < $1.key }
    printLocal(local)
    let notFetched = v.filter { $0.value.result == nil }
    let noPage = v.filter { $0.value.requiredItems == nil }
    print("API not fetched: \(notFetched.map(\.key))")
    print("requirements unknown (page not parsed): \(noPage.map { "\($0.key) [\($0.value.pageState ?? "-")] \($0.value.error ?? "")" })")
    print("removed/not found (result != 1): \(v.filter { ($0.value.result ?? 1) != 1 }.map { "\($0.key) result=\($0.value.result!) \($0.value.localName)" })")
    print("banned: \(v.filter { $0.value.banned == true }.map { "\($0.key) \($0.value.title ?? "") \($0.value.banReason ?? "")" })")
    print("non-public visibility: \(v.filter { ($0.value.visibility ?? 0) != 0 }.map { "\($0.key) vis=\($0.value.visibility!)" })")
    print("behind workshop (online manifest newer than installed): \(v.filter { $0.value.local.behindWorkshop }.map { "\($0.key) \($0.value.title ?? "")" })")
    let timeDiff = v.filter { $0.value.result == 1 && $0.value.timeUpdated != $0.value.local.installedTimeUpdated }
    print("online time_updated != installed timeupdated: \(timeDiff.count) \(timeDiff.prefix(10).map { "\($0.key) online=\($0.value.timeUpdated ?? 0) local=\($0.value.local.installedTimeUpdated ?? 0) manifestSame=\($0.value.manifest == $0.value.local.installedManifest)" })")
    let sizeDiff = v.filter { $0.value.result == 1 && $0.value.manifest == $0.value.local.installedManifest && $0.value.fileSize != $0.value.local.recordedSize }
    print("same manifest but online file_size != recorded size: \(sizeDiff.map { "\($0.key) online=\($0.value.fileSize ?? 0) local=\($0.value.local.recordedSize ?? 0)" })")
    let withReq = v.filter { !($0.value.requiredItems ?? []).isEmpty }
    print("items with required items: \(withReq.count)  (edges: \(withReq.reduce(0) { $0 + $1.value.requiredItems!.count }))")
    let installedIDs = Set(ids)
    let missingReq = withReq.flatMap { e in e.value.requiredItems!.filter { !installedIDs.contains($0.id) }.map { "\(e.key)→\($0.id) \($0.title)" } }
    print("required items not installed: \(missingReq.count) \(missingReq)")
    let withDLC = v.filter { !($0.value.requiredDLC ?? []).isEmpty }
    print("items with required DLC: \(withDLC.count) \(withDLC.map { "\($0.key) \($0.value.title ?? "") → \($0.value.requiredDLC!)" })")
}

/// End-to-end check of WorkshopService against the live API and pages, using a throwaway cache.
@MainActor func live() async {
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent("kitbag-ws-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: cache) }
    let ids = ["450814997", "1118982882", "3666776978", "not-an-id", ""]   // CBA_A3, a mod with requirements, a removed item
    let svc = WorkshopService(cacheURL: cache)
    await svc.setRateLimitPatience(5)   // a 429 pause is reported as .failed instead of waited out
    let a = await svc.details(for: ids, forceRefresh: false)
    check(Set(a.keys) == ["450814997", "1118982882", "3666776978"], "invalid ids dropped: \(a.keys.sorted())")
    for id in a.keys.sorted() {
        let i = a[id]!
        print("  \(id) result=\(i.result.map(String.init) ?? "-") title=\(i.title ?? "-") updated=\(i.timeUpdated ?? 0) manifest=\(i.manifest ?? "-") banned=\(i.banned.map(String.init) ?? "-") vis=\(i.visibility.map(String.init) ?? "-") page=\(i.pageState?.rawValue ?? "-") req=\(i.requiredItems.map { $0.map(\.id).joined(separator: ",") } ?? "-") err=\(i.error ?? "-")")
    }
    check(a["450814997"]?.result == 1 && a["450814997"]?.title == "CBA_A3" && a["450814997"]?.detailsFetchedAt != nil, "CBA details")
    check(a["3666776978"]?.result == 9 && a["3666776978"]?.isRemoved == true && a["3666776978"]?.pageState == .skipped, "removed item: API result 9, page skipped")
    check(a["3666776978"]?.requiredItems == nil, "removed item has unknown requirements, not an empty list")
    for id in ["450814997", "1118982882"] {
        let ps = a[id]?.pageState
        check(ps == .ok || ps == .failed, "\(id) page state \(ps?.rawValue ?? "nil")")
        if ps == .failed { check(a[id]?.error?.contains("429") == true && a[id]?.requiredItems == nil, "\(id) failure is explicit and keeps requirements unknown") }
        if ps == .ok { check(a[id]?.requiredItems != nil && a[id]?.error == nil, "\(id) parsed") }
    }
    if a["1118982882"]?.pageState == .ok {
        check(a["1118982882"]?.requiredItems?.contains { $0.id == "450814997" } == true, "HAFM NAVY requires CBA_A3")
    }

    // Second call: fresh entries are served from the cache without touching the network or their timestamps.
    let b = await svc.details(for: ids, forceRefresh: false)
    check(a["450814997"]?.detailsFetchedAt == b["450814997"]?.detailsFetchedAt, "details cached")
    check(a["3666776978"]?.pageFetchedAt == b["3666776978"]?.pageFetchedAt, "page state cached")
    // A new instance reads the same file.
    let c = await WorkshopService(cacheURL: cache).cached(["450814997"])
    check(c["450814997"]?.title == "CBA_A3", "cache file round-trips")
    let data = (try? Data(contentsOf: cache)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    check((data?["version"] as? Int) == 1 && ((data?["items"] as? [String: Any])?.count == 3), "cache file shape")
    print(failures == 0 ? "live OK" : "live: \(failures) failure(s)")
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "selftest" {
case "selftest":
    selftest()
    exit(failures == 0 ? 0 : 1)
case "live":
    await live()
    exit(failures == 0 ? 0 : 1)
case "local":
    let t0 = Date()
    let s = WorkshopService.localState(steamapps: args.count > 2 ? URL(fileURLWithPath: args[2]) : steamappsDefault)
    print("loaded in \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
    printLocal(s)
case "parse":
    let dir = URL(fileURLWithPath: args[2])
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    // Independent cross-check: the number of requiredItem / requiredDLCItem divs in the raw HTML.
    func count(_ s: String, _ needle: String) -> Int { s.components(separatedBy: needle).count - 1 }
    var mismatches = 0
    for f in files.filter({ $0.pathExtension == "html" }).sorted(by: { $0.path < $1.path }) {
        let html = String(decoding: (try? Data(contentsOf: f)) ?? Data(), as: UTF8.self)
        let id = f.deletingPathExtension().lastPathComponent
        if let p = WorkshopPage.parse(html) {
            let rawItems = count(html, "class=\"requiredItem\""), rawDLC = count(html, "class=\"requiredDLCItem\"")
            let bad = rawItems != p.requiredItems.count || rawDLC != p.requiredDLC.count
            if bad { mismatches += 1 }
            print("\(id)\tok\t\(p.requiredItems.map(\.id).joined(separator: ","))\t\(p.requiredDLC.map(\.appID).joined(separator: ","))\t\(p.title ?? "")\(bad ? "\tMISMATCH raw items=\(rawItems) dlc=\(rawDLC)" : "")")
        } else {
            print("\(id)\tunavailable\t\(WorkshopPage.errorMessage(html) ?? "")")
        }
    }
    print("cross-check mismatches: \(mismatches)")
case "groundtruth":
    let rest = args.dropFirst(2).filter { $0 != "--force" }
    await groundTruth(out: URL(fileURLWithPath: rest.first ?? "Tests/groundtruth/workshop.json"),
                      rawDir: rest.dropFirst().first.map { URL(fileURLWithPath: $0) },
                      force: args.contains("--force"))
default:
    print("usage: run selftest | live | local [steamapps] | parse <dir> | groundtruth <out.json> [rawDir] [--force]")
}
