// Config indexer: reads every config of every loaded PBO (game and mods) once, boils each PBO down to a
// ConfigSummary, and keeps the result in a persistent per-PBO cache so later runs only touch what changed.
import Foundation

// MARK: - Index model

/// What is known about one PBO after reading all of its configs.
struct PBOSummary {
    /// Absolute path of the `.pbo` file.
    let path: String
    let size: Int64
    /// Modification time, seconds since 1970.
    let mtime: TimeInterval
    /// The `prefix` header (lowercased, backslash-separated); "" when the PBO has none.
    let prefix: String
    /// Every config of the PBO merged into one summary. A class path can occur more than once when a
    /// PBO's nested config reopens a class from another of its configs. Mod PBOs carry property
    /// fingerprints; PBOs of the base game do not.
    var summary: ConfigSummary
    /// Normalized paths tested by `__has_include` in this PBO's text configs, and the answer the summary
    /// was built with. Empty when no config depends on the installed set of mods.
    var hasIncludeProbes: [String: Bool] = [:]
    /// PBO-relative paths of the configs that were read (the winner of each folder).
    var configFiles: [String] = []

    var usesHasInclude: Bool { !hasIncludeProbes.isEmpty }
    var name: String { (path as NSString).lastPathComponent }
}

struct ModSummary {
    /// Mod folder, as passed to `ConfigIndexer.build`.
    let path: String
    var hasAddonsFolder: Bool
    /// Only the PBOs Arma loads (`addons/*.pbo`), sorted by path.
    var pbos: [PBOSummary]
    /// `.dll` files in the mod's root when it ships no `.dylib`/`.so`. Informational only: the Mac port
    /// runs the Windows game through Eon, which loads DLLs.
    var windowsOnlyExtensions: [String]
    /// `.dylib`/`.so` files in the mod's root.
    var macExtensions: [String]

    var patches: [PatchInfo] { pbos.flatMap { $0.summary.patches } }
}

/// The base game: what exists and what it inherits from, without properties.
struct VanillaIndex {
    /// CfgPatches names (lowercased) of every addon in the game folder.
    var addons: Set<String> = []
    /// Addon name → the PBO that provides it, as `<game subfolder>/<file>.pbo` (just the file for the root).
    var addonSource: [String: String] = [:]
    /// Class path (lowercased, `/`-joined) → lowercased base class, "" when it has none.
    var parents: [String: String] = [:]
    /// Class paths vanilla only forward-declares (`class X;`) and never defines.
    var externalOnly: Set<String> = []
    /// Every vanilla PBO that was indexed.
    var pbos: [String] = []
    /// Problems reading vanilla configs, each prefixed with the PBO's file name. Expected to be empty.
    var diagnostics: [String] = []

    var classCount: Int { parents.count }
    func hasClass(_ path: String) -> Bool { parents[path.lowercased()] != nil }
    func parent(of path: String) -> String? {
        guard let p = parents[path.lowercased()], !p.isEmpty else { return nil }
        return p
    }
}

struct GameIndex {
    var vanilla = VanillaIndex()
    /// Keyed by mod folder path.
    var mods: [String: ModSummary] = [:]
    /// Mod folders in the order they were given to `build` (the order include lookups prefer).
    var modOrder: [String] = []
    /// Fingerprint of every PBO (path, size, mtime) the index was built from.
    var libraryKey: UInt64 = 0
    /// Mod folders `__has_include` was last answered for by `reindexConditional`; nil = all installed mods.
    var playset: Set<String>?
}

struct IndexStats {
    var pbos = 0
    /// PBOs not read from scratch: their binary configs came from the cache (see `textRefreshed`).
    var cached = 0
    /// PBOs read from scratch (new, changed, or cache unusable).
    var parsed = 0
    /// PBOs whose text configs were redone because the set of installed PBOs changed.
    var textRefreshed = 0
    var binaryConfigs = 0
    var textConfigs = 0
    var cacheBytesRead: Int64 = 0
    var cacheBytesWritten: Int64 = 0
    var cacheWriteFailures = 0
    /// Wall-clock seconds per phase: discover, cache, open, parse, assemble, total.
    var seconds: [String: Double] = [:]
}

// MARK: - Indexer

/// Builds and caches a `GameIndex`.
///
/// Which config Arma loads: every folder of a PBO that holds a `config.cpp` or `config.bin` is an addon of
/// its own, at any depth. When one folder holds both, `config.cpp` is used and `config.bin` ignored — the
/// BI wiki's "Config.cpp/bin File Format" page: no matter the date stamps or content. A sibling `.bin` is
/// only used here as a fallback when the `.cpp` cannot be read, and a `.bin` that disagrees with the
/// `.cpp` about CfgPatches is reported in the diagnostics.
///
/// Cache: one file per PBO in `cacheDirectory`, valid while the PBO's path, size and mtime and
/// `parserVersion` are unchanged. A PBO's text configs also depend on the other PBOs they `#include`, so
/// they are redone whenever any PBO of the library changes; binary configs never are.
final class ConfigIndexer {
    /// Bump when RapParser, TextConfigParser, ConfigPreprocessor, PBOArchive, ConfigSummary.make or this
    /// file change what a summary contains.
    static let parserVersion = 1
    static let cacheFormat: UInt32 = 2
    private static let magic: UInt32 = 0x5849_424B   // "KBIX"

    static var defaultCacheDirectory: URL {
        (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches"))
            .appendingPathComponent("Kitbag/index-v2", isDirectory: true)
    }

    /// nil = no persistence.
    let cacheDirectory: URL?
    let parserVersion: Int
    private(set) var lastStats = IndexStats()
    private let buildLock = NSLock()

    init(cacheDirectory: URL? = ConfigIndexer.defaultCacheDirectory, parserVersion: Int = ConfigIndexer.parserVersion) {
        self.cacheDirectory = cacheDirectory
        self.parserVersion = parserVersion
    }

    /// Indexes the base game and `modFolders`. Only PBOs Arma loads are read. `progress` receives
    /// non-decreasing values in 0...1, possibly from background threads, and must return quickly.
    /// Blocks until done; builds on one indexer run one at a time.
    func build(modFolders: [URL], gameFolder: URL?, progress: ((Double) -> Void)? = nil) -> GameIndex {
        buildLock.lock(); defer { buildLock.unlock() }
        let clock = Stopwatch()
        let report = ProgressReporter(progress)
        var stats = IndexStats()
        var phase = Stopwatch()

        // 1. Discover and stat every PBO.
        var seen = Set<String>()
        let folders = modFolders.filter { seen.insert($0.path).inserted }
        var files: [PBOFile] = []
        if let game = gameFolder {
            for (url, folder) in ConfigIndexer.vanillaPBOs(in: game) {
                if let s = FileStamp(path: url.path) { files.append(PBOFile(url: url, group: -1, folder: folder, stamp: s)) }
            }
        }
        for (m, folder) in folders.enumerated() {
            for url in loadedPBOs(in: folder) {
                if let s = FileStamp(path: url.path) { files.append(PBOFile(url: url, group: m, folder: "", stamp: s)) }
            }
        }
        let libraryKey = ConfigIndexer.libraryKey(files)
        stats.pbos = files.count
        stats.seconds["discover"] = phase.lap()
        report.report(0.02)

        // 2. Reuse whatever the cache still vouches for.
        var records = [PBORecord?](repeating: nil, count: files.count)
        var need = [Need](repeating: .full, count: files.count)
        var bytesRead = [Int64](repeating: 0, count: files.count)
        records.withUnsafeMutableBufferPointer { recs in
            need.withUnsafeMutableBufferPointer { needs in
                bytesRead.withUnsafeMutableBufferPointer { bytes in
                    var done = 0
                    let lock = NSLock()
                    DispatchQueue.concurrentPerform(iterations: files.count) { i in
                        autoreleasepool {
                            if let hit = self.loadCached(files[i]) {
                                recs[i] = hit.record
                                bytes[i] = hit.bytes
                                needs[i] = hit.record.hasText && hit.textLibraryKey != libraryKey ? .text : .none
                            }
                        }
                        lock.lock(); done += 1; let d = done; lock.unlock()
                        if d % 32 == 0 { report.report(0.02 + 0.18 * Double(d) / Double(max(files.count, 1))) }
                    }
                }
            }
        }
        stats.cacheBytesRead = bytesRead.reduce(0, +)
        stats.seconds["cache"] = phase.lap()
        report.report(0.2)

        // 3. Read what the cache could not supply. Includes can point at any PBO, so every PBO is opened
        //    to form the file system the preprocessor sees.
        let work = need.indices.filter { need[$0] != .none }
        if !work.isEmpty {
            var archives = [PBOArchive?](repeating: nil, count: files.count)
            var openErrors = [String?](repeating: nil, count: files.count)
            archives.withUnsafeMutableBufferPointer { arch in
                openErrors.withUnsafeMutableBufferPointer { errs in
                    var done = 0
                    let lock = NSLock()
                    DispatchQueue.concurrentPerform(iterations: files.count) { i in
                        do { arch[i] = try PBOArchive(url: files[i].url) } catch { errs[i] = "\(error)" }
                        lock.lock(); done += 1; let d = done; lock.unlock()
                        if d % 32 == 0 { report.report(0.2 + 0.1 * Double(d) / Double(files.count)) }
                    }
                }
            }
            stats.seconds["open"] = phase.lap()
            report.report(0.3)

            let order = files.indices.filter { files[$0].group >= 0 } + files.indices.filter { files[$0].group < 0 }
            let vfs = VirtualFileSystem(archives: order.compactMap { archives[$0] })

            // Biggest PBOs first so a straggler doesn't end the run alone.
            let queue = work.sorted { files[$0].stamp.size > files[$1].stamp.size }
            var written = [Int64](repeating: 0, count: files.count)
            var writeFailed = [Bool](repeating: false, count: files.count)
            let (opened, openFailures, needs) = (archives, openErrors, need)
            records.withUnsafeMutableBufferPointer { recs in
                written.withUnsafeMutableBufferPointer { wr in
                    writeFailed.withUnsafeMutableBufferPointer { fail in
                        var done = 0
                        let lock = NSLock()
                        DispatchQueue.concurrentPerform(iterations: queue.count) { k in
                            let i = queue[k]
                            autoreleasepool {
                                let mode: ProcessMode = needs[i] == .text ? .textOnly(recs[i]!) : .full
                                var rec = self.process(files[i], archive: opened[i], error: openFailures[i], vfs: vfs, mode: mode)
                                if rec.hasText { rec.textLibraryKey = libraryKey }
                                let payload = RecordCodec.encode(rec)
                                recs[i] = RecordCodec.compacted(payload, like: rec)
                                if self.cacheDirectory != nil {
                                    let n = self.storeCached(files[i], rec, payload: payload)
                                    if n > 0 { wr[i] = n } else { fail[i] = true }
                                }
                            }
                            lock.lock(); done += 1; let d = done; lock.unlock()
                            if d % 8 == 0 { report.report(0.3 + 0.65 * Double(d) / Double(queue.count)) }
                        }
                    }
                }
            }
            stats.cacheBytesWritten = written.reduce(0, +)
            stats.cacheWriteFailures = writeFailed.filter { $0 }.count
        }
        stats.parsed = need.filter { $0 == .full }.count
        stats.textRefreshed = need.filter { $0 == .text }.count
        stats.cached = files.count - stats.parsed
        stats.seconds["parse"] = phase.lap()
        report.report(0.95)

        // 4. Assemble. Records are dropped as they are merged to keep the peak low.
        var index = GameIndex()
        index.libraryKey = libraryKey
        index.modOrder = folders.map(\.path)
        var perGroup = [Int: [Int]]()
        for (i, f) in files.enumerated() { perGroup[f.group, default: []].append(i) }

        for i in perGroup[-1] ?? [] {
            guard let rec = records[i] else { continue }
            records[i] = nil
            let f = files[i]
            let label = f.folder.isEmpty ? f.url.lastPathComponent : f.folder + "/" + f.url.lastPathComponent
            index.vanilla.pbos.append(f.url.path)
            index.vanilla.absorb(rec.merged(), source: label)
            stats.binaryConfigs += rec.binary.files.count
            stats.textConfigs += rec.text.files.count
        }
        for (m, folder) in folders.enumerated() {
            var pbos: [PBOSummary] = []
            for i in perGroup[m] ?? [] {
                guard let rec = records[i] else { continue }
                records[i] = nil
                stats.binaryConfigs += rec.binary.files.count
                stats.textConfigs += rec.text.files.count
                pbos.append(rec.pboSummary(files[i]))
            }
            index.mods[folder.path] = ConfigIndexer.modSummary(folder, pbos: pbos)
        }
        stats.seconds["assemble"] = phase.lap()
        stats.seconds["total"] = clock.elapsed
        report.report(1)
        pruneCache(keepingAtLeast: files.count)
        if stats.parsed > 0 { malloc_zone_pressure_relief(nil, 0) }   // hand the parse buffers back to the system
        lastStats = stats
        return index
    }

    /// Redoes the PBOs whose `__has_include` answers differ when only `enabledModPaths` (plus the base game)
    /// are installed, using that smaller file system for their `#include`s too. Mods outside the set are
    /// left alone. Can be called again with another set, or with every mod to get back to the full-library
    /// answers. Returns the paths of the PBOs that were redone. Nothing is cached: the result is specific
    /// to the playset.
    @discardableResult
    func reindexConditional(index: inout GameIndex, enabledModPaths: Set<String>) -> [String] {
        let enabledOrder = index.modOrder.filter { enabledModPaths.contains($0) && index.mods[$0] != nil }
        var candidates: [(mod: String, i: Int)] = []
        for p in enabledOrder {
            for (i, pbo) in index.mods[p]!.pbos.enumerated() where pbo.usesHasInclude { candidates.append((p, i)) }
        }
        index.playset = enabledModPaths
        guard !candidates.isEmpty else { return [] }

        let urls = enabledOrder.flatMap { index.mods[$0]!.pbos.map { URL(fileURLWithPath: $0.path) } }
            + index.vanilla.pbos.map { URL(fileURLWithPath: $0) }
        var opened = [PBOArchive?](repeating: nil, count: urls.count)
        opened.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: urls.count) { i in buf[i] = try? PBOArchive(url: urls[i]) }
        }
        let vfs = VirtualFileSystem(archives: opened.compactMap { $0 })
        var byPath: [String: PBOArchive] = [:]
        for (u, a) in zip(urls, opened) { if let a { byPath[u.path] = a } }

        let stale = candidates.filter { c in
            index.mods[c.mod]!.pbos[c.i].hasIncludeProbes.contains { vfs.exists($0.key) != $0.value }
        }
        let olds = stale.map { index.mods[$0.mod]!.pbos[$0.i] }
        var results = [PBOSummary?](repeating: nil, count: stale.count)
        results.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: stale.count) { k in
                autoreleasepool {
                    let old = olds[k]
                    let file = PBOFile(url: URL(fileURLWithPath: old.path), group: 0, folder: "",
                                       stamp: FileStamp(size: old.size, mtimeNs: Int64(old.mtime * 1e9)))
                    let rec = self.process(file, archive: byPath[old.path], error: "cannot open", vfs: vfs, mode: .full)
                    out[k] = RecordCodec.compacted(RecordCodec.encode(rec), like: rec).pboSummary(path: old.path, size: old.size, mtime: old.mtime)
                }
            }
        }
        for (c, r) in zip(stale, results) { if let r { index.mods[c.mod]!.pbos[c.i] = r } }
        return stale.map { index.mods[$0.mod]!.pbos[$0.i].path }
    }

    /// Removes every cache file.
    func clearCache() {
        guard let dir = cacheDirectory else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    /// Bytes the cache occupies on disk.
    func cacheSize() -> Int64 {
        guard let dir = cacheDirectory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
        return names.reduce(0) { $0 + (FileStamp(path: dir.appendingPathComponent($1).path)?.size ?? 0) }
    }

    // MARK: Discovery

    /// Base-game PBOs: `<game>/Addons`, `<game>/<DLC>/Addons` and `<game>/Dta/*.pbo`. Numeric folders are
    /// Workshop symlinks, `@…` folders are mods, `.app` folders are bundles.
    static func vanillaPBOs(in game: URL) -> [(url: URL, folder: String)] {
        let fm = FileManager.default
        var out: [(URL, String)] = loadedPBOs(in: game).map { ($0, "") }
        let subs = (try? fm.contentsOfDirectory(at: game, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
        for sub in subs.sorted(by: { $0.path < $1.path }) {
            let name = sub.lastPathComponent
            let v = try? sub.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard v?.isDirectory == true, v?.isSymbolicLink != true, !name.hasPrefix("@"),
                  !name.hasSuffix(".app"), Int(name) == nil else { continue }
            if name.lowercased() == "dta" {
                let pbos = ((try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension.lowercased() == "pbo" }.sorted { $0.path < $1.path }
                out += pbos.map { ($0, name) }
            } else {
                out += loadedPBOs(in: sub).map { ($0, name) }
            }
        }
        return out
    }

    private static func libraryKey(_ files: [PBOFile]) -> UInt64 {
        var h = FNV64()
        for f in files { h.add(f.url.path); h.add(UInt64(bitPattern: f.stamp.size)); h.add(UInt64(bitPattern: f.stamp.mtimeNs)) }
        return h.value
    }

    private static func modSummary(_ folder: URL, pbos: [PBOSummary]) -> ModSummary {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let lower: (String) -> String = { $0.lowercased() }
        let dlls = names.filter { lower($0).hasSuffix(".dll") }.sorted()
        let mac = names.filter { lower($0).hasSuffix(".dylib") || lower($0).hasSuffix(".so") }.sorted()
        var hasAddons = false
        for n in names where lower(n) == "addons" {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(n).path, isDirectory: &isDir), isDir.boolValue { hasAddons = true }
        }
        return ModSummary(path: folder.path, hasAddonsFolder: hasAddons, pbos: pbos,
                          windowsOnlyExtensions: mac.isEmpty ? dlls : [], macExtensions: mac)
    }

    // MARK: Reading one PBO

    /// Which configs of a PBO the game loads: per folder `config.cpp` if present, else `config.bin`.
    private struct Selected {
        let entry: PBOEntry
        /// The `config.bin` this folder's `config.cpp` hides, if any.
        let shadowed: PBOEntry?
    }

    private static func selectConfigs(_ a: PBOArchive) -> [Selected] {
        var cpp: [String: PBOEntry] = [:], bin: [String: PBOEntry] = [:]
        for e in a.entries {
            let p = e.path
            let cut = p.lastIndex(of: "\\")
            let file = cut.map { p[p.index(after: $0)...] } ?? Substring(p)
            guard file == "config.cpp" || file == "config.bin" else { continue }
            let dir = cut.map { String(p[..<$0]) } ?? ""
            if file == "config.cpp" { if cpp[dir] == nil { cpp[dir] = e } } else if bin[dir] == nil { bin[dir] = e }
        }
        return Set(cpp.keys).union(bin.keys).sorted().map { dir in
            cpp[dir].map { Selected(entry: $0, shadowed: bin[dir]) } ?? Selected(entry: bin[dir]!, shadowed: nil)
        }
    }

    private func process(_ f: PBOFile, archive: PBOArchive?, error: String?, vfs: VirtualFileSystem, mode: ProcessMode) -> PBORecord {
        guard let a = archive else {
            var rec = PBORecord()
            rec.binary.summary.diagnostics = ["unreadable pbo: \(f.url.lastPathComponent): \(error ?? "cannot open")"]
            return rec
        }
        var rec = PBORecord()
        var textPaths: Set<String>?
        if case .textOnly(let old) = mode { rec = old; rec.text = PartResult(); textPaths = Set(old.text.files) }
        rec.prefix = a.prefix
        let props = f.withProps
        for s in ConfigIndexer.selectConfigs(a) {
            if let only = textPaths, !only.contains(s.entry.path) { continue }
            let vpath = VirtualFileSystem.path(of: s.entry, in: a)
            guard let data = a.contents(of: s.entry) else {
                rec.binary.summary.diagnostics.append("unreadable config: \(vpath) is truncated")
                continue
            }
            if RapParser.isRapified(data) {
                rec.binary.files.append(s.entry.path)
                rec.binary.summary.append(ConfigIndexer.rapSummary(data, vpath: vpath, props: props))
            } else {
                rec.text.files.append(s.entry.path)
                ConfigIndexer.addText(data, selected: s, archive: a, vpath: vpath, props: props, vfs: vfs, into: &rec.text)
            }
        }
        rec.hasText = !rec.text.files.isEmpty
        rec.binary.summary.capDiagnostics()
        rec.text.summary.capDiagnostics()
        return rec
    }

    private static func rapSummary(_ data: Data, vpath: String, props: Bool) -> ConfigSummary {
        do { return ConfigSummary.make(from: try RapParser.parse(data), includeProperties: props) }
        catch {
            var s = ConfigSummary()
            s.diagnostics = ["parse failure: \(vpath): \(error)"]
            return s
        }
    }

    /// Preprocesses and parses one text config. When it cannot be read cleanly and a `config.bin` sits
    /// beside it, the `.bin` stands in (the diagnostics say so). When both read fine but disagree about
    /// CfgPatches, the `.cpp` still wins and the difference is reported.
    private static func addText(_ data: Data, selected s: Selected, archive a: PBOArchive, vpath: String, props: Bool,
                                vfs: VirtualFileSystem, into part: inout PartResult) {
        let pre = ConfigPreprocessor(vfs: vfs).process(VirtualFileSystem.decode(data), path: vpath)
        for p in Set(pre.usedHasInclude) { part.probes[p] = vfs.exists(p) }
        var diagnostics = pre.diagnostics
        var summary: ConfigSummary?
        var failure: String?
        do { summary = ConfigSummary.make(from: try TextConfigParser.parse(pre.text), includeProperties: props) }
        catch { failure = "parse failure: \(vpath): \(error)" }

        var bin: ConfigClass?
        if let sib = s.shadowed, let bd = a.contents(of: sib), RapParser.isRapified(bd) { bin = try? RapParser.parse(bd) }
        let binPath = s.shadowed.map { VirtualFileSystem.path(of: $0, in: a) } ?? ""

        if let f = failure { diagnostics.append(f) }
        let clean = summary != nil && pre.diagnostics.isEmpty
        if !clean, let bin {
            diagnostics.append("fell back to config.bin: \(binPath) stands in for the unreadable \(vpath)")
            summary = ConfigSummary.make(from: bin, includeProperties: props)
        } else if clean, let sum = summary, let bin {
            let mine = Set(sum.patches.map(PatchSig.init)), theirs = Set(PatchInfo.extract(from: bin).map(PatchSig.init))
            if mine != theirs {
                func list(_ x: Set<PatchSig>) -> String { x.isEmpty ? "nothing" : x.map(\.text).sorted().prefix(3).joined(separator: "; ") }
                diagnostics.append("config shadowed: \(binPath) is ignored because config.cpp wins in the same folder, but their CfgPatches differ "
                    + "(only in .cpp: \(list(mine.subtracting(theirs))); only in .bin: \(list(theirs.subtracting(mine))))")
            }
        }
        var out = summary ?? ConfigSummary()
        out.diagnostics = diagnostics
        part.summary.append(out)
    }

    // MARK: Cache files

    private func cacheFile(for pboPath: String) -> URL? {
        guard let dir = cacheDirectory else { return nil }
        var h = FNV64(); h.add(pboPath)
        return dir.appendingPathComponent(String(format: "%016llx.kbi", h.value))
    }

    /// Layout: "KBIX", u32 format, u32 parser version, u8 withProps, i64 size, i64 mtime ns, u64 text library
    /// key, u8 hasText, u32 path length + path, u32 raw length, u32 payload length, u64 payload checksum,
    /// LZFSE payload. A file that does not match the PBO as it is now, or is damaged, counts as absent.
    private func loadCached(_ f: PBOFile) -> (record: PBORecord, textLibraryKey: UInt64, bytes: Int64)? {
        guard let url = cacheFile(for: f.url.path),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return try? data.withUnsafeBytes { try decodeCacheFile($0, for: f) }
    }

    private func decodeCacheFile(_ raw: UnsafeRawBufferPointer, for f: PBOFile) throws -> (record: PBORecord, textLibraryKey: UInt64, bytes: Int64) {
        let stale = ParseError.format("cache file does not match")
        var s = BinSource(p: raw)
        guard try s.u32() == ConfigIndexer.magic, try s.u32() == ConfigIndexer.cacheFormat,
              try s.u32() == UInt32(truncatingIfNeeded: parserVersion),
              try s.byte() == (f.withProps ? 1 : 0),
              try s.i64() == f.stamp.size, try s.i64() == f.stamp.mtimeNs else { throw stale }
        let textKey = try s.u64(), hasText = try s.byte()
        guard try s.string32() == f.url.path else { throw stale }
        let rawLen = try s.u32(), packedLen = try s.u32(), sum = try s.u64()
        guard Int(packedLen) == raw.count - s.i,
              FNV64.hash(UnsafeRawBufferPointer(rebasing: raw[s.i...])) == sum else { throw stale }
        let packed = Data(bytes: raw.baseAddress! + s.i, count: Int(packedLen))
        let payload = try (packed as NSData).decompressed(using: .lzfse) as Data
        guard payload.count == Int(rawLen) else { throw stale }
        var rec = try payload.withUnsafeBytes { try RecordCodec.decode($0) }
        guard rec.hasText == (hasText == 1) else { throw stale }
        rec.textLibraryKey = textKey
        return (rec, textKey, Int64(raw.count))
    }

    /// Writes the record; returns the file size, or 0 when the write failed.
    private func storeCached(_ f: PBOFile, _ rec: PBORecord, payload: [UInt8]) -> Int64 {
        guard let dir = cacheDirectory, let url = cacheFile(for: f.url.path) else { return 0 }
        guard let packed = try? (Data(payload) as NSData).compressed(using: .lzfse) as Data else { return 0 }
        var w = BinSink()
        w.u32(ConfigIndexer.magic); w.u32(ConfigIndexer.cacheFormat); w.u32(UInt32(truncatingIfNeeded: parserVersion))
        w.byte(f.withProps ? 1 : 0); w.i64(f.stamp.size); w.i64(f.stamp.mtimeNs)
        w.u64(rec.textLibraryKey); w.byte(rec.hasText ? 1 : 0); w.string32(f.url.path)
        w.u32(UInt32(payload.count)); w.u32(UInt32(packed.count))
        w.u64(packed.withUnsafeBytes { FNV64.hash($0) })
        var out = Data(w.b)
        out.append(packed)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try out.write(to: url, options: .atomic)
            return Int64(out.count)
        } catch { return 0 }
    }

    /// Deletes cache files of PBOs that no longer exist. Cheap check first: with no more files than PBOs
    /// there is nothing stale (or nothing worth the reads).
    private func pruneCache(keepingAtLeast count: Int) {
        guard let dir = cacheDirectory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
              names.count > count else { return }
        for n in names where n.hasSuffix(".kbi") {
            let url = dir.appendingPathComponent(n)
            guard let h = try? FileHandle(forReadingFrom: url) else { continue }
            let head = h.readData(ofLength: 38 + 4 + 2048)
            try? h.close()
            let path: String? = head.withUnsafeBytes { raw in
                var s = BinSource(p: raw)
                guard (try? s.skip(38)) != nil else { return nil }
                return try? s.string32()
            }
            if let p = path, !FileManager.default.fileExists(atPath: p) { try? FileManager.default.removeItem(at: url) }
        }
    }
}

// MARK: - Build plumbing

private enum Need { case none, text, full }
private enum ProcessMode { case full, textOnly(PBORecord) }

private struct FileStamp {
    let size: Int64
    let mtimeNs: Int64
    init(size: Int64, mtimeNs: Int64) { self.size = size; self.mtimeNs = mtimeNs }
    init?(path: String) {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        self.init(size: Int64(st.st_size), mtimeNs: Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec))
    }
}

private struct PBOFile {
    let url: URL
    /// -1 for the base game, else the index of the mod folder.
    let group: Int
    let folder: String
    let stamp: FileStamp
    var withProps: Bool { group >= 0 }
}

/// One side of a PBO's configs: either the rapified ones or the ones that needed preprocessing.
struct PartResult {
    var summary = ConfigSummary()
    var files: [String] = []
    var probes: [String: Bool] = [:]
}

/// Everything read from one PBO, kept apart by kind because only the text part goes stale when other PBOs change.
struct PBORecord {
    var prefix = ""
    var binary = PartResult()
    var text = PartResult()
    var hasText = false
    var textLibraryKey: UInt64 = 0

    func merged() -> ConfigSummary {
        var s = binary.summary
        s.append(text.summary)
        return s
    }

    fileprivate func pboSummary(_ f: PBOFile) -> PBOSummary {
        pboSummary(path: f.url.path, size: f.stamp.size, mtime: Double(f.stamp.mtimeNs) / 1e9)
    }

    func pboSummary(path: String, size: Int64, mtime: TimeInterval) -> PBOSummary {
        PBOSummary(path: path, size: size, mtime: mtime, prefix: prefix, summary: merged(),
                   hasIncludeProbes: text.probes, configFiles: (binary.files + text.files).sorted())
    }
}

private extension ConfigSummary {
    mutating func append(_ other: ConfigSummary) {
        if patches.isEmpty && classes.isEmpty && diagnostics.isEmpty { self = other; return }
        patches += other.patches; classes += other.classes; diagnostics += other.diagnostics
    }

    /// A broken include can repeat the same complaint thousands of times.
    mutating func capDiagnostics(_ limit: Int = 200) {
        if diagnostics.count > limit { diagnostics = Array(diagnostics.prefix(limit)) + ["… \(diagnostics.count - limit) more"] }
    }
}

private extension VanillaIndex {
    /// Folds one PBO's classes in. Defined classes beat forward declarations; the first base class named wins.
    mutating func absorb(_ s: ConfigSummary, source: String) {
        for p in s.patches { addons.insert(p.name); if addonSource[p.name] == nil { addonSource[p.name] = source } }
        diagnostics += s.diagnostics.map { "\(source): \($0)" }
        for c in s.classes {
            if c.external {
                if parents[c.path] == nil { parents[c.path] = ""; externalOnly.insert(c.path) }
                continue
            }
            externalOnly.remove(c.path)
            if let known = parents[c.path] {
                if known.isEmpty, let base = c.parent { parents[c.path] = base }
            } else {
                parents[c.path] = c.parent ?? ""
            }
        }
    }
}

/// What a CfgPatches entry says that matters for loading, so text and binary versions can be compared.
private struct PatchSig: Hashable {
    let name: String
    let required: [String]
    let skip: Bool
    init(_ p: PatchInfo) { name = p.name; required = p.requiredAddons; skip = p.skipWhenMissingDependencies }
    var text: String { "\(name) requires [\(required.joined(separator: ","))]" + (skip ? " (skipWhenMissingDependencies)" : "") }
}

private struct Stopwatch {
    private var start = DispatchTime.now().uptimeNanoseconds
    private var mark = DispatchTime.now().uptimeNanoseconds
    var elapsed: Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9 }
    mutating func lap() -> Double {
        let now = DispatchTime.now().uptimeNanoseconds
        defer { mark = now }
        return Double(now - mark) / 1e9
    }
}

private final class ProgressReporter {
    private let callback: ((Double) -> Void)?
    private let lock = NSLock()
    private var last = 0.0
    init(_ callback: ((Double) -> Void)?) { self.callback = callback }

    /// Callbacks run under the lock so values reach the caller in order.
    func report(_ value: Double) {
        guard let callback else { return }
        lock.lock(); defer { lock.unlock() }
        let v = min(1, max(value, last))
        guard v - last >= 0.005 || (v >= 1 && last < 1) else { return }
        last = v
        callback(v)
    }
}

/// FNV-1a, 64 bit: cache keys and checksums, not security.
private struct FNV64 {
    private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325
    private mutating func mix(_ byte: UInt8) { value = (value ^ UInt64(byte)) &* 0x100_0000_01b3 }
    mutating func add(_ s: String) { for b in s.utf8 { mix(b) }; mix(0xFF) }
    mutating func add(_ v: UInt64) { for k in 0..<8 { mix(UInt8(truncatingIfNeeded: v >> (8 * k))) } }
    static func hash(_ raw: UnsafeRawBufferPointer) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in raw { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return h
    }
}

// MARK: - Record codec

/// Compact binary form of a `PBORecord`. Strings that repeat (property names, fingerprints, parents) go
/// through a table; class paths are unique, so they are written in place.
enum RecordCodec {
    static func encode(_ r: PBORecord) -> [UInt8] {
        var e = Encoder()
        e.body.string(r.prefix)
        e.part(r.binary, probes: false)
        e.part(r.text, probes: true)
        var out = BinSink()
        out.varint(e.list.count)
        for s in e.list { out.string(s) }
        out.b.append(contentsOf: e.body.b)
        return out.b
    }

    static func decode(_ raw: UnsafeRawBufferPointer) throws -> PBORecord {
        var s = BinSource(p: raw)
        let n = try s.count()
        var table: [String] = []
        table.reserveCapacity(n)
        for _ in 0..<n { table.append(try s.string()) }
        var d = Decoder(s: s, table: table)
        var r = PBORecord()
        r.prefix = try d.s.string()
        r.binary = try d.part(probes: false)
        r.text = try d.part(probes: true)
        guard d.s.i == raw.count else { throw ParseError.format("trailing bytes in cached record") }
        r.hasText = !r.text.files.isEmpty
        return r
    }

    /// What a cache load of `payload` would produce: equal strings and equal property dictionaries are shared,
    /// which is a good deal smaller than the freshly parsed record. Falls back to `record` should decoding fail.
    static func compacted(_ payload: [UInt8], like record: PBORecord) -> PBORecord {
        guard var r = try? payload.withUnsafeBytes({ try decode($0) }) else { return record }
        r.textLibraryKey = record.textLibraryKey
        return r
    }

    fileprivate struct Encoder {
        var table: [String: Int] = [:]
        var list: [String] = []
        /// Property dictionaries seen so far, so a class with the same properties as an earlier one refers back to it.
        var dicts: [[String: String]: Int] = [:]
        var body = BinSink()

        mutating func ref(_ s: String) {
            if let i = table[s] { body.varint(i); return }
            table[s] = list.count
            body.varint(list.count)
            list.append(s)
        }

        mutating func part(_ p: PartResult, probes: Bool) {
            body.varint(p.files.count)
            for f in p.files { body.string(f) }
            if probes {
                body.varint(p.probes.count)
                for (k, v) in p.probes { body.string(k); body.byte(v ? 1 : 0) }
            }
            let s = p.summary
            body.varint(s.patches.count)
            for x in s.patches {
                ref(x.name)
                body.varint(x.requiredAddons.count)
                for a in x.requiredAddons { ref(a) }
                if let v = x.requiredVersion { body.byte(1); body.u64(v.bitPattern) } else { body.byte(0) }
                body.byte(x.skipWhenMissingDependencies ? 1 : 0)
            }
            body.varint(s.classes.count)
            for c in s.classes {
                body.string(c.path)
                if let parent = c.parent { body.byte(c.external ? 3 : 1); ref(parent) } else { body.byte(c.external ? 2 : 0) }
                if c.props.isEmpty {
                    body.varint(0)
                } else if let seen = dicts[c.props] {
                    body.varint(seen + 2)
                } else {
                    dicts[c.props] = dicts.count
                    body.varint(1); body.varint(c.props.count)
                    for (k, v) in c.props { ref(k); ref(v) }
                }
                body.varint(c.deletes.count)
                for d in c.deletes { ref(d) }
            }
            body.varint(s.diagnostics.count)
            for d in s.diagnostics { body.string(d) }
        }
    }

    fileprivate struct Decoder {
        var s: BinSource
        let table: [String]
        /// Distinct property dictionaries in the order the encoder met them; classes that share one share its storage.
        var dicts: [[String: String]] = []

        mutating func ref() throws -> String {
            let i = try s.varint()
            guard i < table.count else { throw ParseError.format("string reference out of range") }
            return table[i]
        }

        mutating func part(probes: Bool) throws -> PartResult {
            var p = PartResult()
            for _ in 0..<(try s.count()) { p.files.append(try s.string()) }
            if probes {
                for _ in 0..<(try s.count()) { let k = try s.string(); p.probes[k] = try s.byte() == 1 }
            }
            for _ in 0..<(try s.count()) {
                let name = try ref()
                var req: [String] = []
                for _ in 0..<(try s.count()) { req.append(try ref()) }
                let version: Double? = try s.byte() == 1 ? Double(bitPattern: try s.u64()) : nil
                let skip = try s.byte() == 1
                p.summary.patches.append(PatchInfo(name: name, requiredAddons: req, requiredVersion: version, skipWhenMissingDependencies: skip))
            }
            let n = try s.count()
            p.summary.classes.reserveCapacity(n)
            for _ in 0..<n {
                let path = try s.string()
                let flags = try s.byte()
                guard flags <= 3 else { throw ParseError.format("bad class flags") }
                let parent: String? = flags & 1 != 0 ? try ref() : nil
                var props: [String: String] = [:]
                switch try s.varint() {
                case 0: break
                case 1:
                    let n = try s.count()
                    props.reserveCapacity(n)
                    for _ in 0..<n { let k = try ref(); props[k] = try ref() }
                    dicts.append(props)
                case let t:
                    guard t - 2 < dicts.count else { throw ParseError.format("property dictionary reference out of range") }
                    props = dicts[t - 2]
                }
                var deletes: [String] = []
                for _ in 0..<(try s.count()) { deletes.append(try ref()) }
                p.summary.classes.append(ClassDef(path: path, parent: parent, external: flags & 2 != 0, props: props, deletes: deletes))
            }
            for _ in 0..<(try s.count()) { p.summary.diagnostics.append(try s.string()) }
            return p
        }
    }
}

private struct BinSink {
    var b: [UInt8] = []
    mutating func byte(_ v: UInt8) { b.append(v) }
    mutating func varint(_ v: Int) {
        var x = UInt64(v)
        while x >= 0x80 { b.append(UInt8(x & 0x7F) | 0x80); x >>= 7 }
        b.append(UInt8(x))
    }
    mutating func u32(_ v: UInt32) { for k in 0..<4 { b.append(UInt8(truncatingIfNeeded: v >> (8 * k))) } }
    mutating func u64(_ v: UInt64) { for k in 0..<8 { b.append(UInt8(truncatingIfNeeded: v >> (8 * k))) } }
    mutating func i64(_ v: Int64) { u64(UInt64(bitPattern: v)) }
    mutating func string(_ s: String) { varint(s.utf8.count); b.append(contentsOf: s.utf8) }
    mutating func string32(_ s: String) { u32(UInt32(s.utf8.count)); b.append(contentsOf: s.utf8) }
}

/// Bounds-checked reader: corrupt or truncated cache bytes throw instead of trapping.
private struct BinSource {
    let p: UnsafeRawBufferPointer
    var i = 0
    init(p: UnsafeRawBufferPointer) { self.p = p }

    mutating func byte() throws -> UInt8 {
        guard i < p.count else { throw ParseError.eof }
        defer { i += 1 }
        return p[i]
    }
    mutating func skip(_ n: Int) throws {
        guard n >= 0, n <= p.count - i else { throw ParseError.eof }
        i += n
    }
    mutating func varint() throws -> Int {
        var v: UInt64 = 0
        for shift in stride(from: 0, to: 63, by: 7) {
            let b = try byte()
            v |= UInt64(b & 0x7F) << UInt64(shift)
            if b & 0x80 == 0 {
                guard v <= UInt64(Int32.max) else { throw ParseError.format("varint too large") }
                return Int(v)
            }
        }
        throw ParseError.format("varint too long")
    }
    /// An element count; every element takes at least a byte, so a larger count is corrupt.
    mutating func count() throws -> Int {
        let n = try varint()
        guard n <= p.count - i else { throw ParseError.format("count exceeds data") }
        return n
    }
    mutating func u32() throws -> UInt32 {
        guard p.count - i >= 4 else { throw ParseError.eof }
        defer { i += 4 }
        return UInt32(p[i]) | UInt32(p[i + 1]) << 8 | UInt32(p[i + 2]) << 16 | UInt32(p[i + 3]) << 24
    }
    mutating func u64() throws -> UInt64 {
        let lo = UInt64(try u32()), hi = UInt64(try u32())
        return hi << 32 | lo
    }
    mutating func i64() throws -> Int64 { Int64(bitPattern: try u64()) }
    private mutating func text(_ n: Int) throws -> String {
        guard n >= 0, n <= p.count - i else { throw ParseError.eof }
        defer { i += n }
        return String(decoding: UnsafeRawBufferPointer(rebasing: p[i..<(i + n)]), as: UTF8.self)
    }
    mutating func string() throws -> String { try text(try varint()) }
    mutating func string32() throws -> String { try text(Int(try u32())) }
}
