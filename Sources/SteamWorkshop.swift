// Steam Workshop state: what Steam recorded locally for Arma 3's Workshop items, and what the
// Workshop reports online (title, update time, removed/banned, required items and DLC).
import Foundation

// MARK: - Valve KeyValues

/// Valve KeyValues text (VDF / ACF): `"key" "value"` pairs and `"key" { … }` blocks.
/// Keys match case-insensitively, as in Steam; order and duplicate keys are preserved.
struct KeyValues {
    struct Entry {
        let key: String
        let node: KeyValues
    }

    var value: String?
    var children: [Entry] = []

    var isBlock: Bool { value == nil }

    subscript(_ key: String) -> KeyValues? {
        let k = key.lowercased()
        return children.first { $0.key.lowercased() == k }?.node
    }

    /// Nested lookup, e.g. `kv.node("AppWorkshop", "WorkshopItemsInstalled")`.
    func node(_ path: String...) -> KeyValues? {
        var n: KeyValues? = self
        for k in path { n = n?[k] }
        return n
    }

    var string: String? { value }
    var int: Int64? { value.flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) } }

    /// Parses a whole document. Returns nil on malformed input (unterminated string or block,
    /// stray `}`), so a file Steam is half-way through writing is never half-read.
    /// `//` comments and `[$PLATFORM]` conditionals are skipped; `\"`, `\\`, `\n`, `\t` are unescaped.
    static func parse(_ text: String) -> KeyValues? {
        var lexer = KVLexer(Array(text.utf8))
        guard let root = try? lexer.block(depth: 0) else { return nil }
        return KeyValues(value: nil, children: root)
    }

    static func parse(contentsOf url: URL) -> KeyValues? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return parse(String(decoding: d, as: UTF8.self))
    }
}

private struct KVLexer {
    enum Token { case string(String), open, close }

    let b: [UInt8]
    var i = 0

    init(_ bytes: [UInt8]) {
        b = bytes
        if b.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3 }
    }

    mutating func block(depth: Int) throws -> [KeyValues.Entry] {
        var out: [KeyValues.Entry] = []
        while let t = try next() {
            switch t {
            case .close:
                guard depth > 0 else { throw ParseError.format("unexpected }") }
                return out
            case .open:
                throw ParseError.format("block without a key")
            case .string(let key):
                switch try next() {
                case .string(let v)?: out.append(.init(key: key, node: KeyValues(value: v)))
                case .open?: out.append(.init(key: key, node: KeyValues(value: nil, children: try block(depth: depth + 1))))
                default: throw ParseError.format("key without a value")
                }
            }
        }
        if depth > 0 { throw ParseError.eof }
        return out
    }

    mutating func next() throws -> Token? {
        while i < b.count {
            let c = b[i]
            switch c {
            case 0x20, 0x09, 0x0A, 0x0D:
                i += 1
            case 0x2F where i + 1 < b.count && b[i + 1] == 0x2F:   // // comment
                while i < b.count && b[i] != 0x0A { i += 1 }
            case 0x5B:                                               // [$WIN32] conditional
                while i < b.count && b[i] != 0x5D { i += 1 }
                i += 1
            case 0x7B: i += 1; return .open
            case 0x7D: i += 1; return .close
            case 0x22:
                i += 1
                var s: [UInt8] = []
                while true {
                    guard i < b.count else { throw ParseError.eof }
                    let ch = b[i]; i += 1
                    if ch == 0x22 { break }
                    if ch == 0x5C, i < b.count {
                        let e = b[i]; i += 1
                        switch e {
                        case 0x6E: s.append(0x0A)
                        case 0x74: s.append(0x09)
                        case 0x5C, 0x22: s.append(e)
                        default: s.append(ch); s.append(e)
                        }
                    } else {
                        s.append(ch)
                    }
                }
                return .string(String(decoding: s, as: UTF8.self))
            default:   // bare token
                let start = i
                loop: while i < b.count {
                    switch b[i] {
                    case 0x20, 0x09, 0x0A, 0x0D, 0x22, 0x7B, 0x7D: break loop
                    default: i += 1
                    }
                }
                return .string(String(decoding: b[start..<i], as: UTF8.self))
            }
        }
        return nil
    }
}

// MARK: - Local state (appworkshop_107410.acf)

/// What Steam has recorded about Arma 3's Workshop items in one Steam library,
/// checked against the item folders actually present in `workshop/content/107410`.
struct WorkshopLocalState {
    static let appID = "107410"

    /// Workshop IDs are plain decimal numbers; anything else in the content folder is not an item.
    static func isWorkshopID(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }

    /// `WorkshopItemsInstalled`: the version Steam last finished writing to disk.
    struct Installed: Codable, Hashable {
        let size: Int64           // exact sum of the item's file sizes
        let timeUpdated: Int64
        let manifest: String      // "-1" for legacy single-file uploads
        let ugcHandle: String?    // legacy uploads only
    }

    /// `WorkshopItemDetails`: one entry per item this account is subscribed to. `manifest`/`timeUpdated`
    /// equal the installed record for all 243 items of the reference library; `latest*` is the newest
    /// version Steam has seen on the Workshop and is what differs while an update is pending.
    struct Details: Codable, Hashable {
        let manifest: String
        let timeUpdated: Int64
        let timeTouched: Int64
        let subscribedBy: String?
        let latestTimeUpdated: Int64
        let latestManifest: String
    }

    enum SizeCheck: Hashable {
        case match
        /// Fewer bytes on disk than Steam installed: files missing or truncated.
        case missing(Int64)
        /// More bytes on disk than Steam installed (Finder metadata excluded): files added or edited.
        case extra(Int64)
        /// No install record, no folder, or Steam is still writing the item.
        case unknown
    }

    struct Item {
        let id: String
        let folder: URL?
        let installed: Installed?
        let details: Details?
        /// Bytes of regular files under the folder (symlinks not followed); nil without a folder.
        let actualSize: Int64?
        /// Part of `actualSize` that is Finder metadata (`.DS_Store`, `._*`, `Icon\r`).
        let finderMetadataSize: Int64
        /// Steam has a staging folder for it in `workshop/downloads` or `workshop/temp`.
        let downloading: Bool
        /// False when the .acf could not be read; every record-based flag is then false.
        let recordsAvailable: Bool

        var tracked: Bool { installed != nil }
        var subscribed: Bool { details != nil }

        /// Steam knows newer content than the one installed (it downloads it when Arma isn't running).
        /// Compares manifests, since a metadata-only edit on the Workshop bumps `latest_timeupdated`
        /// without new content; legacy uploads (manifest -1) have only the timestamp to go on.
        var needsUpdate: Bool {
            guard let inst = installed, let d = details else { return false }
            let latest = d.latestManifest
            if isLegacy || latest.isEmpty || latest == "0" { return d.latestTimeUpdated > inst.timeUpdated }
            return latest != inst.manifest
        }

        /// Folder present but Steam neither installed nor subscribes to it: a leftover from an
        /// unsubscribed item (or a manual copy) that Steam will never update or remove.
        var orphan: Bool { recordsAvailable && folder != nil && installed == nil && details == nil && !downloading }

        /// Installed by Steam but no longer among this account's subscriptions; Steam normally
        /// deletes such items on its next Workshop sync, so it may vanish from the mod list.
        var unsubscribed: Bool { recordsAvailable && installed != nil && details == nil }

        /// Subscribed but not (yet) downloaded.
        var awaitingDownload: Bool { recordsAvailable && details != nil && installed == nil }

        /// Steam has an install record but the folder is gone.
        var missingFolder: Bool { installed != nil && folder == nil }

        /// Legacy single-file upload (`<ugchandle>_legacy.bin`, usually a scenario), not a mod folder.
        var isLegacy: Bool { installed.map { $0.manifest == "-1" || $0.ugcHandle != nil } ?? false }

        /// Steam's recorded `size` is the exact byte sum of the files it wrote: all 243 items in the
        /// reference library match to the byte, including two that ship dotfiles. So the tolerance is
        /// zero, except that Finder metadata may account for a surplus. Any other difference means the
        /// folder changed after Steam wrote it (interrupted download, deleted or edited files).
        var sizeCheck: SizeCheck {
            guard let inst = installed, let actual = actualSize, !downloading else { return .unknown }
            if actual < inst.size { return .missing(inst.size - actual) }
            let surplus = actual - finderMetadataSize - inst.size
            return surplus > 0 ? .extra(surplus) : .match
        }

        var sizeMismatch: Bool {
            switch sizeCheck { case .missing, .extra: return true; default: return false }
        }

        /// Fewer bytes on disk than Steam installed. Only this says content is missing; a surplus
        /// (`.extra`) means files were added or changed, which is not an incomplete download.
        var incomplete: Bool {
            if case .missing = sizeCheck { return true }
            return false
        }
    }

    let steamapps: URL
    /// nil when appworkshop_107410.acf is missing or unreadable.
    let records: KeyValues?
    let appNeedsUpdate: Bool
    let appNeedsDownload: Bool
    let lastUpdated: Date?
    /// Every item that has a folder, an install record or a subscription record, keyed by Workshop ID.
    let items: [String: Item]

    var acfLoaded: Bool { records != nil }

    /// Reads the .acf and walks the content folder. `measureSizes: false` skips summing file sizes
    /// (sizeCheck is then `.unknown`); with sizes, ~6,000 files take about 20 ms with warm filesystem caches.
    static func load(steamapps: URL, measureSizes: Bool = true) -> WorkshopLocalState {
        let fm = FileManager.default
        let ws = steamapps.appendingPathComponent("workshop")
        let acf = ws.appendingPathComponent("appworkshop_\(appID).acf")
        let kv = KeyValues.parse(contentsOf: acf)
        let root = kv?["AppWorkshop"]

        var installed: [String: Installed] = [:]
        for e in root?["WorkshopItemsInstalled"]?.children ?? [] where e.node.isBlock {
            let n = e.node
            installed[e.key] = Installed(size: n["size"]?.int ?? 0, timeUpdated: n["timeupdated"]?.int ?? 0,
                                      manifest: n["manifest"]?.string ?? "", ugcHandle: n["ugchandle"]?.string)
        }
        var details: [String: Details] = [:]
        for e in root?["WorkshopItemDetails"]?.children ?? [] where e.node.isBlock {
            let n = e.node
            details[e.key] = Details(manifest: n["manifest"]?.string ?? "", timeUpdated: n["timeupdated"]?.int ?? 0,
                                  timeTouched: n["timetouched"]?.int ?? 0, subscribedBy: n["subscribedby"]?.string,
                                  latestTimeUpdated: n["latest_timeupdated"]?.int ?? 0,
                                  latestManifest: n["latest_manifest"]?.string ?? "")
        }

        func dirs(_ u: URL) -> [String: URL] {
            let list = (try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            var out: [String: URL] = [:]
            for d in list where isWorkshopID(d.lastPathComponent)
                && (try? d.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                out[d.lastPathComponent] = d
            }
            return out
        }
        let folders = dirs(ws.appendingPathComponent("content/\(appID)"))
        let staging = Set(dirs(ws.appendingPathComponent("downloads/\(appID)")).keys)
            .union(dirs(ws.appendingPathComponent("temp/\(appID)")).keys)

        let ids = Array(Set(folders.keys).union(installed.keys).union(details.keys)).sorted()
        var sizes = [(Int64, Int64)?](repeating: nil, count: ids.count)
        if measureSizes {
            sizes.withUnsafeMutableBufferPointer { buf in
                DispatchQueue.concurrentPerform(iterations: ids.count) { i in
                    if let f = folders[ids[i]] { buf[i] = folderSize(f) }
                }
            }
        }
        var items: [String: Item] = [:]
        for (i, id) in ids.enumerated() {
            items[id] = Item(id: id, folder: folders[id], installed: installed[id], details: details[id],
                             actualSize: sizes[i]?.0, finderMetadataSize: sizes[i]?.1 ?? 0,
                             downloading: staging.contains(id), recordsAvailable: kv != nil)
        }
        return WorkshopLocalState(
            steamapps: steamapps, records: kv,
            appNeedsUpdate: root?["NeedsUpdate"]?.int.map { $0 != 0 } ?? false,
            appNeedsDownload: root?["NeedsDownload"]?.int.map { $0 != 0 } ?? false,
            lastUpdated: root?["TimeLastUpdated"]?.int.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil },
            items: items)
    }

    /// (all regular-file bytes, Finder-metadata bytes) under `folder`, without following symlinks.
    static func folderSize(_ folder: URL) -> (Int64, Int64) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return (0, 0) }
        var total: Int64 = 0, meta: Int64 = 0
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let n = Int64(v.fileSize ?? 0)
            total += n
            let name = u.lastPathComponent
            if name == ".DS_Store" || name.hasPrefix("._") || name == "Icon\r" { meta += n }
        }
        return (total, meta)
    }
}

// MARK: - Online details

/// What the Workshop says about one item. Parts that were never fetched successfully are nil.
struct WorkshopItemInfo: Codable, Hashable {
    struct Requirement: Codable, Hashable {
        let id: String
        let title: String
    }

    struct DLC: Codable, Hashable {
        let appID: String
        let name: String
    }

    /// Outcome of reading the public item page.
    enum PageState: String, Codable {
        case ok            // parsed; requiredItems/requiredDLC are complete (possibly empty)
        case unavailable   // Steam served no item page (removed, private, or behind a login)
        case skipped       // not fetched: the API says the item doesn't exist
        case failed        // network/HTTP failure; earlier data, if any, is kept
    }

    let id: String

    // ISteamRemoteStorage/GetPublishedFileDetails
    /// Steam EResult: 1 = OK, 9 = not found (removed, or private to anonymous callers).
    var result: Int?
    var title: String?
    var timeCreated: Int64?
    var timeUpdated: Int64?
    var fileSize: Int64?
    /// `hcontent_file`: the content manifest (or legacy UGC handle), comparable with the .acf's.
    var manifest: String?
    var banned: Bool?
    var banReason: String?
    /// 0 public, 1 friends only, 2 private, 3 unlisted.
    var visibility: Int?
    var tags: [String]?
    var detailsFetchedAt: Date?

    // steamcommunity.com/sharedfiles/filedetails page
    var requiredItems: [Requirement]?
    var requiredDLC: [DLC]?
    var pageState: PageState?
    var pageFetchedAt: Date?

    /// Last failure for this item, if the most recent refresh of any part failed.
    var error: String?

    init(id: String) { self.id = id }

    var exists: Bool? { result.map { $0 == 1 } }
    var isRemoved: Bool { result == 9 }
    var isBanned: Bool { banned == true }
}

extension WorkshopLocalState.Item {
    /// The Workshop has a newer version than the one on disk, even if Steam hasn't noticed yet.
    /// Requires both a different content manifest and a later update time, so metadata-only
    /// edits on the Workshop page (which bump nothing in the manifest) never trigger it.
    func isBehind(_ info: WorkshopItemInfo) -> Bool {
        guard let inst = installed, info.exists == true, let m = info.manifest, !m.isEmpty, m != "0",
              let t = info.timeUpdated else { return false }
        let local = inst.manifest == "-1" ? (inst.ugcHandle ?? "") : inst.manifest
        return m != local && t > inst.timeUpdated
    }
}

/// Fetches Workshop details (Steam Web API, no key) and the public item pages (required items and
/// DLC), with a 24-hour JSON cache. Only Workshop IDs are ever sent; no cookies are kept.
actor WorkshopService {
    static let shared = WorkshopService()

    static let defaultCacheURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/Kitbag/workshop-v1.json")

    let cacheURL: URL
    let ttl: TimeInterval
    /// Minimum spacing between page requests. Measured on a few hundred pages: steamcommunity.com serves about
    /// 20 item pages per rolling ten minutes whatever the spacing (1.2 s and 6 s both ran into 429
    /// after 20), then answers 429 for 9 to 12 minutes. A playset-sized batch therefore finishes in
    /// seconds, and a whole library takes about two hours; callers should fetch what they need.
    var pageInterval: TimeInterval = 1.2
    /// How long a page fetch may sit out a 429 pause before giving up with `.failed`. The cache keeps
    /// what was fetched, so calling `details` again later resumes. Set high to wait out a full block.
    var rateLimitPatience: TimeInterval = 150
    /// When set, raw page HTML is saved here as `<id>.html` (for checking the parser).
    var rawPageDirectory: URL?

    private let session: URLSession
    private var cache: [String: WorkshopItemInfo]?
    private var nextPageAt = Date.distantPast
    private var backoff: TimeInterval = 30

    init(cacheURL: URL = WorkshopService.defaultCacheURL, ttl: TimeInterval = 24 * 3600) {
        self.cacheURL = cacheURL
        self.ttl = ttl
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpShouldSetCookies = false
        cfg.urlCache = nil
        cfg.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh) Kitbag/1.0"]
        session = URLSession(configuration: cfg)
    }

    func setRawPageDirectory(_ url: URL?) { rawPageDirectory = url }
    func setPageInterval(_ s: TimeInterval) { pageInterval = s }
    func setRateLimitPatience(_ s: TimeInterval) { rateLimitPatience = s }

    static func localState(steamapps: URL, measureSizes: Bool = true) -> WorkshopLocalState {
        WorkshopLocalState.load(steamapps: steamapps, measureSizes: measureSizes)
    }

    /// Cached info for every id (no network).
    func cached(_ ids: [String]) -> [String: WorkshopItemInfo] {
        let c = loadCache()
        return Dictionary(uniqueKeysWithValues: ids.compactMap { id in c[id].map { (id, $0) } })
    }

    /// Details and requirements for `ids`, refreshing whatever is older than the TTL (or everything
    /// with `forceRefresh`). Always returns an entry per id; if a refresh fails the previous data is
    /// kept and `error` says why. `progress` reports (finished, total) page fetches.
    func details(for ids: [String], forceRefresh: Bool = false,
                 progress: (@Sendable (Int, Int) -> Void)? = nil) async -> [String: WorkshopItemInfo] {
        var c = loadCache()
        let wanted = Array(Set(ids.filter(WorkshopLocalState.isWorkshopID))).sorted()
        let now = Date()
        func stale(_ d: Date?) -> Bool { forceRefresh || d.map { now.timeIntervalSince($0) > ttl } ?? true }

        for id in wanted where c[id] == nil { c[id] = WorkshopItemInfo(id: id) }

        // 1. Web API, ≤100 ids per request.
        let needDetails = wanted.filter { stale(c[$0]?.detailsFetchedAt) }
        for start in stride(from: 0, to: needDetails.count, by: 100) {
            let batch = Array(needDetails[start..<min(start + 100, needDetails.count)])
            switch await fetchDetails(batch) {
            case .success(let got):
                for id in batch {
                    if var info = got[id] {
                        info.requiredItems = c[id]?.requiredItems
                        info.requiredDLC = c[id]?.requiredDLC
                        info.pageState = c[id]?.pageState
                        info.pageFetchedAt = c[id]?.pageFetchedAt
                        c[id] = info
                    } else {
                        c[id]?.error = "Steam returned no entry for this item"
                    }
                }
            case .failure(let e):
                for id in batch { c[id]?.error = "Workshop API: \(e.localizedDescription)" }
            }
            if start + 100 < needDetails.count { try? await Task.sleep(nanoseconds: 300_000_000) }
        }

        // 2. Item pages, paced, at most 2 in flight. Progress is saved every 25 pages, since a
        // full library takes minutes.
        let needPages = wanted.filter { stale(c[$0]?.pageFetchedAt) }
        var done = 0
        await withTaskGroup(of: (String, PageOutcome).self) { group in
            var queue = needPages[...]
            func launch() {
                guard !Task.isCancelled, let id = queue.popFirst() else { return }
                if c[id]?.result.map({ $0 != 1 }) == true {   // the API says it doesn't exist
                    group.addTask { (id, .skipped) }
                } else {
                    group.addTask { await (id, self.fetchPage(id)) }
                }
            }
            launch(); launch()
            while let (id, outcome) = await group.next() {
                switch outcome {
                case .parsed(let p):
                    c[id]?.requiredItems = p.requiredItems
                    c[id]?.requiredDLC = p.requiredDLC
                    if c[id]?.title == nil { c[id]?.title = p.title }
                    c[id]?.pageState = .ok
                    c[id]?.pageFetchedAt = Date()
                    if c[id]?.error?.hasPrefix("Workshop page") == true { c[id]?.error = nil }
                case .unavailable(let why) where c[id]?.result == 1:
                    // The API says the item exists, so an error page is treated as transient.
                    if c[id]?.pageState == nil { c[id]?.pageState = .failed }
                    c[id]?.error = "Workshop page: \(why)"
                case .unavailable(let why):
                    c[id]?.requiredItems = nil
                    c[id]?.requiredDLC = nil
                    c[id]?.pageState = .unavailable
                    c[id]?.pageFetchedAt = Date()
                    c[id]?.error = "Workshop page: \(why)"
                case .skipped:
                    c[id]?.requiredItems = nil
                    c[id]?.requiredDLC = nil
                    c[id]?.pageState = .skipped
                    c[id]?.pageFetchedAt = Date()
                case .failed(let why):
                    if c[id]?.pageState == nil { c[id]?.pageState = .failed }
                    c[id]?.error = "Workshop page: \(why)"
                }
                done += 1
                progress?(done, needPages.count)
                if done % 25 == 0 { store(c, wanted) }
                launch()
            }
        }

        store(c, wanted)
        return Dictionary(uniqueKeysWithValues: wanted.compactMap { id in c[id].map { (id, $0) } })
    }

    /// Writes `ids` from `c` into the cache. Merges rather than replaces: another call may have
    /// refreshed other items meanwhile.
    private func store(_ c: [String: WorkshopItemInfo], _ ids: [String]) {
        var merged = loadCache()
        for id in ids { merged[id] = c[id] }
        cache = merged
        saveCache()
    }

    // MARK: Web API

    private func fetchDetails(_ ids: [String]) async -> Result<[String: WorkshopItemInfo], Error> {
        var req = URLRequest(url: URL(string: "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = "itemcount=\(ids.count)"
        for (i, id) in ids.enumerated() { body += "&publishedfileids%5B\(i)%5D=\(id)" }
        req.httpBody = Data(body.utf8)

        var lastError: Error = URLError(.unknown)
        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(2 << attempt) * 1_000_000_000) }
            do {
                let (data, resp) = try await session.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200 else { lastError = URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"]); continue }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let list = (json["response"] as? [String: Any])?["publishedfiledetails"] as? [[String: Any]] else {
                    lastError = URLError(.cannotParseResponse); continue
                }
                let now = Date()
                var out: [String: WorkshopItemInfo] = [:]
                for d in list {
                    guard let id = Self.str(d["publishedfileid"]) else { continue }
                    var info = WorkshopItemInfo(id: id)
                    info.result = Self.int(d["result"]).map(Int.init)
                    info.title = Self.str(d["title"])
                    info.timeCreated = Self.int(d["time_created"])
                    info.timeUpdated = Self.int(d["time_updated"])
                    info.fileSize = Self.int(d["file_size"])
                    info.manifest = Self.str(d["hcontent_file"])
                    info.banned = Self.int(d["banned"]).map { $0 != 0 }
                    info.banReason = Self.str(d["ban_reason"]).flatMap { $0.isEmpty ? nil : $0 }
                    info.visibility = Self.int(d["visibility"]).map(Int.init)
                    info.tags = (d["tags"] as? [[String: Any]])?.compactMap { Self.str($0["tag"]) }
                    info.detailsFetchedAt = now
                    out[id] = info
                }
                return .success(out)
            } catch {
                lastError = error
            }
        }
        return .failure(lastError)
    }

    private static func str(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    private static func int(_ v: Any?) -> Int64? {
        if let n = v as? NSNumber { return n.int64Value }
        if let s = v as? String { return Int64(s) }
        return nil
    }

    // MARK: Item pages

    private enum PageOutcome {
        case parsed(WorkshopPage.Parsed)
        case unavailable(String)
        case skipped
        case failed(String)
    }

    /// Waits for this request's turn. Slots are handed out before suspending, so concurrent callers
    /// stay `pageInterval` apart.
    private func pageSlot() async {
        let now = Date()
        let at = max(now, nextPageAt)
        nextPageAt = at.addingTimeInterval(pageInterval)
        let wait = at.timeIntervalSince(now)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
    }

    /// A 429: pause all page requests, and slow down for the rest of the session. Requests already
    /// in flight when the pause started don't escalate it again.
    private func rateLimited() {
        let now = Date()
        guard nextPageAt < now.addingTimeInterval(backoff / 2) else { return }
        nextPageAt = now.addingTimeInterval(backoff)
        backoff = min(backoff * 2, 300)
        pageInterval = min(pageInterval * 1.5, 6)
    }

    private func fetchPage(_ id: String) async -> PageOutcome {
        let url = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)")!
        var last = "no response"
        for _ in 0..<6 {
            if nextPageAt.timeIntervalSinceNow > rateLimitPatience { return .failed("HTTP 429 (rate limited), try again in a few minutes") }
            await pageSlot()
            if Task.isCancelled { return .failed("cancelled") }
            do {
                let (data, resp) = try await session.data(from: url)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 429 || code == 503 { last = "HTTP \(code) (rate limited)"; rateLimited(); continue }
                guard code == 200 else { last = "HTTP \(code)"; continue }
                backoff = 30
                let html = String(decoding: data, as: UTF8.self)
                if let dir = rawPageDirectory {
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try? data.write(to: dir.appendingPathComponent("\(id).html"))
                }
                if let p = WorkshopPage.parse(html) { return .parsed(p) }
                return .unavailable(WorkshopPage.errorMessage(html) ?? "no item page")
            } catch {
                last = error.localizedDescription
            }
        }
        return .failed(last)
    }

    // MARK: Cache

    private struct CacheFile: Codable {
        var version = 1
        var items: [String: WorkshopItemInfo]
    }

    private func loadCache() -> [String: WorkshopItemInfo] {
        if let c = cache { return c }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        let c = (try? Data(contentsOf: cacheURL)).flatMap { try? dec.decode(CacheFile.self, from: $0) }
        cache = c?.version == 1 ? c?.items ?? [:] : [:]
        return cache!
    }

    private func saveCache() {
        guard let c = cache else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(CacheFile(items: c)) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}

// MARK: - Item page parsing

/// Reads the public Workshop item page. Relies only on markup Steam has used for years: the
/// `RequiredItems` container (links to `filedetails/?id=`) and the `requiredDLCContainer`
/// (links to `store.steampowered.com/app/<id>` with a `requiredDLCName`).
enum WorkshopPage {
    struct Parsed: Hashable {
        var title: String?
        var requiredItems: [WorkshopItemInfo.Requirement]
        var requiredDLC: [WorkshopItemInfo.DLC]
    }

    /// nil when the HTML is not an item page (error page, login wall, truncated download).
    static func parse(_ html: String) -> Parsed? {
        // Requirements live in the sidebar; bound the search so description links never count.
        // Without a recognisable sidebar the page is rejected rather than read as "no requirements".
        guard html.contains("class=\"workshopItemTitle\""), html.contains("id=\"sharedfiles_content_ctn\""),
              let sidebar = section(html, from: "id=\"rightContents\"", to: ["<!-- created by -->", "class=\"creatorsBlock\""])
        else { return nil }
        var p = Parsed(title: firstMatch(html, #"<div class="workshopItemTitle">([\s\S]*?)</div>"#).map(text),
                       requiredItems: [], requiredDLC: [])

        if let block = section(sidebar, from: "id=\"RequiredItems\"", to: ["rightSectionTopTitle", "class=\"panel\""]) {
            var seen = Set<String>()
            for m in matches(block, #"href="https?://steamcommunity\.com/(?:sharedfiles|workshop)/filedetails/\?id=(\d+)[^"]*"[^>]*>([\s\S]*?)</a>"#)
            where seen.insert(m[0]).inserted {
                p.requiredItems.append(.init(id: m[0], title: text(m[1])))
            }
        }
        if let block = section(sidebar, from: "class=\"requiredDLCContainer\"", to: ["rightSectionTopTitle", "class=\"panel\""]) {
            var names: [String: String] = [:], order: [String] = []
            for m in matches(block, #"href="https?://store\.steampowered\.com/app/(\d+)[^"]*"[^>]*>([\s\S]*?)</a>"#) {
                if names[m[0]] == nil { order.append(m[0]); names[m[0]] = "" }
                let t = text(m[1])
                if names[m[0]]!.isEmpty && !t.isEmpty { names[m[0]] = t }
            }
            p.requiredDLC = order.map { .init(appID: $0, name: names[$0]!.isEmpty ? "App \($0)" : names[$0]!) }
        }
        return p
    }

    /// Steam's own explanation on an error page, if any (e.g. "There was a problem accessing the item.").
    static func errorMessage(_ html: String) -> String? {
        for re in [#"<div class="error_ctn">([\s\S]*?)</div>\s*</div>"#, #"<h3>([\s\S]*?)</h3>"#] {
            if let m = firstMatch(html, re) {
                let t = text(m)
                if !t.isEmpty { return String(t.prefix(200)) }
            }
        }
        return nil
    }

    /// Text from `start` (inclusive) up to the earliest of `ends` after it, or nil when `start` is absent.
    private static func section(_ s: String, from start: String, to ends: [String]) -> String? {
        guard let a = s.range(of: start) else { return nil }
        let rest = s[a.upperBound...]
        let end = ends.compactMap { rest.range(of: $0)?.lowerBound }.min() ?? rest.endIndex
        return String(rest[..<end])
    }

    private static func firstMatch(_ s: String, _ pattern: String) -> String? {
        matches(s, pattern).first?.first
    }

    /// Capture groups (from 1) of every match.
    private static func matches(_ s: String, _ pattern: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { m in
            (1..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
        }
    }

    /// Visible text of an HTML fragment: tags dropped, entities decoded, whitespace collapsed.
    static func text(_ html: String) -> String {
        var t = html.replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression)
        t = decodeEntities(t)
        return t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let name = s[s.index(after: i)..<semi]
                var rep: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    rep = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if name.hasPrefix("#") {
                    rep = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else {
                    rep = named[String(name)]
                }
                if let r = rep { out += r; i = s.index(after: semi); continue }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }
}
