// Game-log evidence: reads the Eon wrapper's log (eon.txt) so Kitbag can check its static
// findings against what the game really did — extension loads, missing-addon dialogs,
// crash context — instead of guessing.
//
// What the log does and does not contain (measured on the Mac port, see Tests/gamelog):
//  • Every line is `[thread 0000000a][W][12345]: text` — level I/W/E and milliseconds since the
//    wrapper started. There is no wall-clock time. A few messages carry unprefixed continuation lines.
//  • The wrapper logs the engine's DLL loads (`DLL LOADING: <path> loaded (fully bound) …`), failed
//    loads/exports, the game's stdout/stderr, and every Win32 MessageBox as an [E] line. Arma reports
//    "Addon 'X' requires addon 'Y'" through a MessageBox, which blocks the game until dismissed.
//  • It does NOT carry the engine's RPT stream: a several-minute session with 90 mods printed no config
//    warnings or script errors, and no .rpt file exists. The config/script matchers below only fire
//    if a future wrapper starts forwarding RPT text; on current logs they stay empty by design.
import Foundation

// MARK: - Report

/// Everything worth knowing from one wrapper log. Entries are capped so a spammy mod can't flood the UI.
struct GameLogReport {
    /// A mod extension (`<name>_x64.dll`) the engine tried to load.
    struct ExtensionLoad: Hashable {
        /// Mod folder (one of the `modFolders` passed in) when the path could be attributed.
        var modPath: String?
        /// File name as logged, e.g. `ace_x64.dll`.
        var dll: String
        var loaded: Bool
        /// The wrapper's own wording: `loaded (fully bound)`, or the failure message.
        var detail: String
    }

    /// "Addon 'addon' requires addon 'requiredBy'" — note the wording: `addon` is the *missing* one.
    struct MissingAddon: Hashable {
        /// The addon that could not be found (the one the dialog says is required).
        var addon: String
        /// The addon that asked for it.
        var requiredBy: String
        /// Mod that owns `requiredBy`, when the caller supplied `addonOwners` and it matched.
        var modPath: String?
        /// `requiredBy` is a base-game addon (`A3_…`): an installation problem, not a mod's fault.
        var isGameAddon: Bool
        var raw: String
    }

    /// One line of interest, with the mod it names (if any) and why we think so.
    struct Entry: Hashable {
        var line: String
        var modPath: String?
        /// `workshop path`, `local mod path`, or `PBO prefix <prefix>`; nil when unattributed.
        var attribution: String?
        var ms: Int?
    }

    var extensionLoads: [ExtensionLoad] = []
    var missingAddons: [MissingAddon] = []
    var configErrors: [Entry] = []
    var scriptErrors: [Entry] = []
    /// Dialogs and wrapper errors that are not missing addons, crash signals, failed library loads.
    var wrapperErrors: [Entry] = []
    /// The last non-noise lines of the log (raw), for showing crash context.
    var lastLines: [String] = []
    /// Mod folders whose logo the engine asked for when building the Mods menu — proof the engine
    /// received them in `-mod=`. A lower bound: mods without a logo file never appear.
    var listedMods: [String] = []
    /// Wall-clock bounds. The log has none, so these are only set from an RPT-style
    /// `Current time:` line or by `GameLog.load` (from the file's modification time).
    var startedAt: Date?
    var endedAt: Date?
    /// Milliseconds from wrapper start to the last logged line.
    var elapsedMs = 0
    var lineCount = 0
    /// The Windows executable was loaded, i.e. the game got past the wrapper's own startup.
    /// When false the launch itself failed (e.g. the wrapper crashed in its first 3 lines) and no mod can be blamed.
    var reachedEngine = false
    /// Entries dropped by the per-category cap.
    var droppedEntries = 0

    /// Extensions that failed to load.
    var failedExtensions: [ExtensionLoad] { extensionLoads.filter { !$0.loaded } }
    /// Missing addons caused by mods (not the base game install).
    var modMissingAddons: [MissingAddon] { missingAddons.filter { !$0.isGameAddon } }
    /// Nothing the report would show as a problem.
    var isClean: Bool {
        failedExtensions.isEmpty && modMissingAddons.isEmpty && configErrors.isEmpty
            && scriptErrors.isEmpty && wrapperErrors.isEmpty
    }
}

// MARK: - Parsing

enum GameLog {
    /// Where the Eon wrapper writes its log. It is overwritten on every launch.
    static var defaultURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.vpltd.Arma3/eon.txt")

    static let maxEntriesPerCategory = 200
    static let lastLineCount = 40

    /// Parse log text. `modFolders` are the absolute mod paths passed to the game; lines naming one
    /// are attributed to it. `prefixIndex` (from `GameLog.prefixIndex`) lets lines that only name a
    /// PBO prefix (`z\ace\addons\common\…`) be attributed too — built on demand when omitted and
    /// needed. `addonOwners` maps lowercased addon class → mod path for `MissingAddon.modPath`.
    /// `aliases` maps other paths the game saw (Kitbag's `!Kitbag/<n>` links) → the mod path.
    static func parse(_ text: String, modFolders: [String],
                      prefixIndex: [String: [String]]? = nil,
                      addonOwners: [String: String] = [:],
                      aliases: [String: String] = [:]) -> GameLogReport {
        var report = GameLogReport()
        let who = Attributor(modFolders: modFolders, prefixIndex: prefixIndex, aliases: aliases)
        var recent: [String] = []          // ring of the last non-noise raw lines
        var listed = Set<String>(), seenLoads = Set<String>(), seenMissing = Set<String>()
        var counts: [String: Int] = [:]

        func add(_ entry: GameLogReport.Entry, to keyPath: WritableKeyPath<GameLogReport, [GameLogReport.Entry]>, _ key: String) {
            if report[keyPath: keyPath].count >= maxEntriesPerCategory { report.droppedEntries += 1; return }
            // Identical lines repeat (one per frame, per unit…); keep the first few.
            counts[key + entry.line, default: 0] += 1
            if counts[key + entry.line]! > 1 { return }
            report[keyPath: keyPath].append(entry)
        }
        func entry(_ raw: String, _ body: String, ms: Int) -> GameLogReport.Entry {
            let hit = who.mod(in: body)
            return .init(line: clip(raw), modPath: hit?.path, attribution: hit?.how, ms: ms)
        }

        for rec in records(text) {
            report.lineCount += 1
            report.elapsedMs = max(report.elapsedMs, rec.ms)
            let t = rec.text
            let noise = isNoise(t)
            if !noise { recent.append(rec.raw); if recent.count > lastLineCount { recent.removeFirst() } }

            // --- DLL loads -------------------------------------------------------------
            if t.hasPrefix("DLL LOADING: ") {
                let (path, state) = parseDLLLine(t)
                let low = windowsKey(path)
                if low.hasSuffix("arma3retail_dx11_x64.exe") || low.hasSuffix("arma3_x64.exe") || low.hasSuffix("arma3retail_x64.exe") {
                    report.reachedEngine = true
                }
                if let owner = modOwner(of: low, who) {
                    let name = fileName(path)
                    if seenLoads.insert(low + "|" + state).inserted {
                        report.extensionLoads.append(.init(modPath: owner.path, dll: name,
                                                           loaded: state.hasPrefix("loaded"), detail: state))
                    }
                }
                continue
            }
            if let path = firstMatch(loadFailRE, in: t) {
                let low = windowsKey(path)
                if let owner = modOwner(of: low, who) {
                    if seenLoads.insert(low + "|fail").inserted {
                        report.extensionLoads.append(.init(modPath: owner.path, dll: fileName(path), loaded: false, detail: clip(t)))
                    }
                } else if !harmlessLibraries.contains(fileName(path).lowercased()) {
                    add(entry(rec.raw, t, ms: rec.ms), to: \.wrapperErrors, "w")
                }
                continue
            }
            if let m = captures(procFailRE, in: t), m.count == 2 {
                // A missing export on a loaded mod DLL: Arma probes several entry-point spellings
                // (RVExtension, RVExtensionArgs, _RVExtension@12…), so this is detail, never a failure.
                let lib = m[0].lowercased()
                if let i = report.extensionLoads.lastIndex(where: { $0.dll.lowercased() == lib }) {
                    report.extensionLoads[i].detail += "; no export '\(m[1])'"
                }
                continue
            }

            // --- MessageBox dialogs (missing addons, config errors, fatal errors) ------------
            if t.hasPrefix("MessageBox"), let box = captures(messageBoxRE, in: t), box.count >= 2 {
                let body = box[0]
                if let m = captures(missingAddonRE, in: body), m.count == 2 {
                    let key = (m[0] + ">" + m[1]).lowercased()
                    if seenMissing.insert(key).inserted {
                        report.missingAddons.append(.init(addon: m[1], requiredBy: m[0],
                                                          modPath: addonOwners[m[0].lowercased()],
                                                          isGameAddon: m[0].lowercased().hasPrefix("a3_"), raw: clip(rec.raw)))
                    }
                } else if isConfigText(body) {
                    add(entry(rec.raw, body, ms: rec.ms), to: \.configErrors, "c")
                } else {
                    add(entry(rec.raw, body, ms: rec.ms), to: \.wrapperErrors, "w")
                }
                continue
            }

            // --- Mod logo lookups: which mods the engine received ----------------------------
            if t.hasPrefix("vpfs_CreateFileA returns ERROR_INVALID_NAME"), t.contains("dtaExt\\") {
                // Wrapper path-join bug (`dtaExt\c:\…\mod.paa`): harmless, but it names each mod.
                if let hit = who.mod(in: t), listed.insert(hit.path).inserted { report.listedMods.append(hit.path) }
                continue
            }

            // --- Game stdout/stderr and RPT-style text ---------------------------------------
            let gamePrefix = gameTextPrefixes.first { t.hasPrefix($0) }
            if gamePrefix != nil || rec.level == "E" || rec.level == "W" {
                // One record may hold a whole multi-line error ("Error in expression", "Error position", "File …, line N").
                var pieces = t.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                if let gamePrefix, !pieces.isEmpty { pieces[0] = String(pieces[0].dropFirst(gamePrefix.count)).trimmingCharacters(in: .whitespaces) }
                let body = pieces
                let kind: WritableKeyPath<GameLogReport, [GameLogReport.Entry]>? =
                    body.contains(where: { matches(scriptRE, $0) }) ? \.scriptErrors
                    : body.contains(where: { matches(configRE, $0) }) ? \.configErrors : nil
                if let kind {
                    let full = ([rec.raw] + body.dropFirst()).joined(separator: "\n")
                    add(entry(full, body.joined(separator: " "), ms: rec.ms), to: kind, kind == \.scriptErrors ? "s" : "c")
                    continue
                }
            }

            // --- Wrapper-level problems -----------------------------------------------------
            if !noise, isWrapperProblem(t, level: rec.level) {
                add(entry(rec.raw, t, ms: rec.ms), to: \.wrapperErrors, "w")
            }
            if report.startedAt == nil, let when = rptTime(t) { report.startedAt = when }
        }
        report.lastLines = recent
        return report
    }

    /// Read and parse a log file. Dates come from the file: it was last written when the game
    /// ended, and the wrapper's millisecond clock starts at launch.
    static func load(_ url: URL = defaultURL, modFolders: [String],
                     prefixIndex: [String: [String]]? = nil,
                     addonOwners: [String: String] = [:],
                     aliases: [String: String] = [:]) -> GameLogReport? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        var report = parse(String(decoding: data, as: UTF8.self), modFolders: modFolders,
                           prefixIndex: prefixIndex, addonOwners: addonOwners, aliases: aliases)
        if let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            report.endedAt = report.endedAt ?? modified
            if report.startedAt == nil { report.startedAt = modified.addingTimeInterval(-Double(report.elapsedMs) / 1000) }
        }
        return report
    }

    /// PBO prefix → mod folders that ship a PBO with it (headers only, so it is quick even for
    /// large libraries). Pass the result to `parse` when parsing several logs.
    static func prefixIndex(modFolders: [String]) -> [String: [String]] {
        var perMod = [[String]](repeating: [], count: modFolders.count)
        perMod.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: modFolders.count) { i in
                var seen = Set<String>()
                for pbo in loadedPBOs(in: URL(fileURLWithPath: modFolders[i])) {
                    if let p = try? PBOArchive(url: pbo).prefix, p.contains("\\") { seen.insert(p) }
                }
                buf[i] = Array(seen)
            }
        }
        var index: [String: [String]] = [:]
        for (i, prefixes) in perMod.enumerated() { for p in prefixes { index[p, default: []].append(modFolders[i]) } }
        return index
    }

    // MARK: Archive

    /// Logs smaller than this stopped inside the wrapper's own startup (a crashed launch writes ~250
    /// bytes, a real session tens of KB). They say nothing about mods, so they are not archived.
    static let minArchiveBytes = 1024

    /// Copy the current log to `dir` as `arma3-<yyyyMMdd-HHmmss>.eon.txt` (named after when it was
    /// last written) and keep only the newest `keep` copies. Call after the game exits — the next
    /// launch overwrites the original. Returns nil when there is no log worth keeping.
    @discardableResult
    static func archiveCurrentLog(to dir: URL, keep: Int = 10) -> URL? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: defaultURL.path),
              (attrs[.size] as? NSNumber)?.intValue ?? 0 >= minArchiveBytes,
              let modified = attrs[.modificationDate] as? Date else { return nil }
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let dest = dir.appendingPathComponent("arma3-\(f.string(from: modified)).eon.txt")
        if !fm.fileExists(atPath: dest.path) {
            do { try fm.copyItem(at: defaultURL, to: dest) } catch { return nil }
        }
        for old in archivedLogs(in: dir).dropFirst(max(keep, 1)) { try? fm.removeItem(at: old) }
        return dest
    }

    /// Archived logs in `dir`, newest first.
    static func archivedLogs(in dir: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("arma3-") && $0.lastPathComponent.hasSuffix(".eon.txt") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    // MARK: Records

    private struct Record {
        let level: Character
        let ms: Int
        var text: String     // message; continuation lines of game output are appended after "\n"
        let raw: String      // the first line, as logged
    }

    /// Split into prefixed records. Unprefixed lines belong to the previous record, but only game
    /// output keeps them (shader dumps and the like would just be memory).
    private static func records(_ text: String) -> [Record] {
        var out: [Record] = []
        var room = 0
        for sub in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = sub.hasSuffix("\r") ? sub.dropLast() : sub
            if line.hasPrefix("[thread "), let rec = record(line) {
                out.append(rec)
                room = gameTextPrefixes.contains { rec.text.hasPrefix($0) } ? 12 : 0
            } else if room > 0, !out.isEmpty {
                let extra = line.trimmingCharacters(in: .whitespaces)
                if !extra.isEmpty { out[out.count - 1].text += "\n" + extra; room -= 1 }
            }
        }
        return out
    }

    /// `[thread 0000000a][W][12345]: text`
    private static func record(_ line: Substring) -> Record? {
        guard let close = line.firstIndex(of: "]") else { return nil }
        var i = line.index(after: close)
        guard i < line.endIndex, line[i] == "[" else { return nil }
        i = line.index(after: i)
        guard i < line.endIndex else { return nil }
        let level = line[i]
        i = line.index(after: i)
        guard line[i...].hasPrefix("][") else { return nil }
        i = line.index(i, offsetBy: 2)
        guard let end = line[i...].firstIndex(of: "]"), let ms = Int(line[i..<end]) else { return nil }
        var t = line[line.index(after: end)...]
        guard t.hasPrefix(": ") else { return Record(level: level, ms: ms, text: String(t), raw: String(line)) }
        t = t.dropFirst(2)
        return Record(level: level, ms: ms, text: String(t), raw: String(line))
    }

    // MARK: Classification

    /// Prefixes the wrapper puts on text the game itself printed (stdout/stderr, OutputDebugString).
    private static let gameTextPrefixes = ["Game stdout/err:", "[OutputDebugString]"]

    /// Chatter that appears in every healthy session; never shown and kept out of `lastLines`.
    private static let noisePrefixes = [
        "RaiseException code=0x406d1388",          // SetThreadName
        "Unknown MSVC exception triggered by the game",
        "Synchronously wait for data transfer", "Created another data streaming buffer",
        "Overlapped scatter/gather read", "Compiling compute pipeline", "Patching shader",
        "Calling TLS callback", "Done calling TLS callback", "GetModuleHandleEx",
        "REGISTRY OPERATION: RegOpenKeyExW() returns ERROR_NOT_FOUND",
        "Precompiled shader cache", "NSError in file", "description: 'Fragment input",
        "Vertex shader text", "Pixel shader text", "Loading icons doesn't support",
        "vpfs_CreateFileA returns ERROR_INVALID_NAME",
    ]
    private static func isNoise(_ t: String) -> Bool { noisePrefixes.contains { t.hasPrefix($0) } }

    /// [E]-level wrapper lines seen in healthy sessions.
    private static let harmlessErrors = ["Internal error in fs_FindNextFileA?"]
    /// Engine libraries the wrapper fails to find in every healthy session.
    private static let harmlessLibraries: Set<String> = ["tbb4malloc_bi.dll", "tbb4malloc_bi_x64.dll"]

    private static let crashRE = regex(#"(?i)unhandled exception|access violation|segmentation fault|\bsigsegv\b|\bsigabrt\b|fatal error|stack overflow|out of memory|assertion failed|\bcrash(?:ed)?\b"#)
    private static let raiseRE = regex(#"RaiseException code=0x([0-9a-fA-F]+)"#)

    private static func isWrapperProblem(_ t: String, level: Character) -> Bool {
        if level == "E" { return !harmlessErrors.contains { t.hasPrefix($0) } }
        if let m = captures(raiseRE, in: t), m.first?.lowercased() != "406d1388" { return true }
        return level == "W" && matches(crashRE, t)
    }

    private static let loadFailRE = regex(#"^eON_LoadLibraryEx\(\) couldn't load '(.+)', returning NULL!"#)
    private static let procFailRE = regex(#"^eON_GetProcAddress\(\).*in PE file '(.+)' FAILED\. Proc not found at name '(.+)'"#)
    private static let messageBoxRE = regex(#"^MessageBox[AW]\(.*?text = '(.*)', caption = '(.*)', type = (\d+)\s*\)\s*$"#)
    private static let missingAddonRE = regex(#"^Addon '(.+)' requires addon '(.+)'$"#)
    private static let rptTimeRE = regex(#"Current time:\s+(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2})"#)

    /// Arma's script-error lines (as they appear in an RPT or on stderr).
    private static let scriptRE = regex(#"^(?:\d{1,2}:\d{2}:\d{2}\s+)?(?:Error in expression\b|Error position:|Error (?:Undefined variable|Missing|Type\b|Zero divisor|Generic error|Foreign error|Invalid number|\d+ elements? provided)|Error compiling|Script \S+ not found|File \S+, line \d+)"#)
    /// Config problems (as they appear in an RPT or in a dialog).
    private static let configRE = regex(#"^(?:\d{1,2}:\d{2}:\d{2}\s+)?(?:Warning Message:|Updating base class|Config\s*:|Include file .+ not found|Undefined base class|.+\.(?:cpp|hpp|inc|bin), line \d+:)"#)

    private static func isConfigText(_ s: String) -> Bool { matches(configRE, s) || matches(configDialogRE, s) }
    private static let configDialogRE = regex(#"(?i)\bconfig\b|include file|\.(?:cpp|hpp|bin)\b|\bclass\b.*\b(?:not|undefined|missing)\b"#)

    private static func rptTime(_ t: String) -> Date? {
        guard let s = firstMatch(rptTimeRE, in: t) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return f.date(from: s)
    }

    /// `DLL LOADING: <path> loaded (fully bound) at 0x…` → (path, "loaded (fully bound)").
    /// Anything not saying "loaded" is reported as-is so a different wrapper wording reads as a failure.
    private static func parseDLLLine(_ t: String) -> (String, String) {
        let rest = String(t.dropFirst("DLL LOADING: ".count))
        if let r = rest.range(of: " loaded (") {
            let path = String(rest[..<r.lowerBound])
            let tail = rest[r.upperBound...]
            let state = tail.firstIndex(of: ")").map { "loaded (" + tail[..<$0] + ")" } ?? "loaded"
            return (path, state)
        }
        if let r = rest.range(of: " loaded") { return (String(rest[..<r.lowerBound]), "loaded") }
        return (rest, clip(rest))
    }

    // MARK: Helpers

    private static func clip(_ s: String, _ n: Int = 600) -> String { s.count > n ? String(s.prefix(n)) + "…" : s }

    private static func fileName(_ path: String) -> String {
        path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? path
    }

    /// Lowercase, backslashes, no drive letter: `C:\Users\Me\X` and `/Users/Me/X` both become `\users\me\x`.
    static func windowsKey(_ path: String) -> String {
        var p = path.lowercased().replacingOccurrences(of: "/", with: "\\")
        if p.count >= 2, p.dropFirst().hasPrefix(":"), let c = p.first, c.isLetter { p.removeFirst(2) }
        return p
    }

    /// A DLL belongs to a mod when its path names a known mod folder or has a mod-folder shape
    /// (Workshop id, symlinked id under the game folder, `@name`).
    private static func modOwner(of key: String, _ who: Attributor) -> (path: String?, how: String)? {
        if let hit = who.mod(inKey: key, usePrefixes: false) { return (hit.path, hit.how) }
        if key.range(of: #"\\107410\\\d+\\"#, options: .regularExpression) != nil
            || key.range(of: #"\\arma 3\\(?:\d+|@[^\\]+)\\"#, options: .regularExpression) != nil {
            return (nil, "mod folder path")
        }
        return nil
    }

    private static func regex(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// Capture groups of the first match (empty string for a group that didn't take part).
    private static func captures(_ re: NSRegularExpression, in s: String) -> [String]? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (1..<max(m.numberOfRanges, 1)).map { Range(m.range(at: $0), in: s).map { String(s[$0]) } ?? "" }
    }

    private static func firstMatch(_ re: NSRegularExpression, in s: String) -> String? { captures(re, in: s)?.first }

    // MARK: Attribution

    /// Maps text to the mod it names: by mod-folder path (Workshop id, `@name`, any known folder), then by PBO prefix.
    private final class Attributor {
        private var folderKeys: [(key: String, path: String)] = []
        private var byID: [String: String] = [:]
        private var byName: [String: String] = [:]
        private var prefixes: [String: String]?
        private let modFolders: [String]
        private let given: [String: [String]]?

        private static let idRE = try! NSRegularExpression(pattern: #"\\(?:107410|arma 3)\\(\d+)(?=\\|\W|$)"#)
        private static let nameRE = try! NSRegularExpression(pattern: #"\\(@[^\\]+)(?=\\)"#)
        private static let tokenRE = try! NSRegularExpression(pattern: #"[a-z0-9_@\-\.]+(?:\\[a-z0-9_@\-\.]+)+"#)

        init(modFolders: [String], prefixIndex: [String: [String]]?, aliases: [String: String] = [:]) {
            self.modFolders = modFolders
            self.given = prefixIndex
            for path in modFolders {
                let key = GameLog.windowsKey(path)
                folderKeys.append((key, path))
                let last = URL(fileURLWithPath: path).lastPathComponent.lowercased()
                if Int(last) != nil { byID[last] = byID[last] ?? path }
                if last.hasPrefix("@") { byName[last] = byName[last] ?? path }
            }
            // A relative alias key ("!kitbag\12") matches both relative and absolute log paths.
            for (alias, path) in aliases { folderKeys.append((GameLog.windowsKey(alias), path)) }
        }

        func mod(in text: String) -> (path: String, how: String)? {
            mod(inKey: GameLog.windowsKey(text), usePrefixes: true)
        }

        func mod(inKey key: String, usePrefixes: Bool) -> (path: String, how: String)? {
            let ns = key as NSString
            let all = NSRange(location: 0, length: ns.length)
            if let m = Attributor.idRE.firstMatch(in: key, range: all), let p = byID[ns.substring(with: m.range(at: 1))] {
                return (p, "workshop path")
            }
            if let m = Attributor.nameRE.firstMatch(in: key, range: all), let p = byName[ns.substring(with: m.range(at: 1))] {
                return (p, "local mod path")
            }
            for (k, p) in folderKeys where !k.isEmpty {
                var from = key.startIndex
                while let r = key.range(of: k, range: from..<key.endIndex) {
                    if r.upperBound == key.endIndex || !(key[r.upperBound].isLetter || key[r.upperBound].isNumber) { return (p, "mod path") }
                    from = r.upperBound
                }
            }
            guard usePrefixes else { return nil }
            let index = prefixOwners()
            guard !index.isEmpty else { return nil }
            for m in Attributor.tokenRE.matches(in: key, range: all) {
                var parts = ns.substring(with: m.range).split(separator: "\\").map(String.init)
                while parts.count >= 2 {
                    let candidate = parts.joined(separator: "\\")
                    if let p = index[candidate] { return (p, "PBO prefix \(candidate)") }
                    parts.removeLast()
                }
            }
            return nil
        }

        /// Prefixes with exactly one owner (a shared prefix can't tell us which mod printed the line).
        private func prefixOwners() -> [String: String] {
            if let p = prefixes { return p }
            let source = given ?? GameLog.prefixIndex(modFolders: modFolders)
            var unique: [String: String] = [:]
            for (prefix, owners) in source where Set(owners).count == 1 { unique[prefix.lowercased()] = owners[0] }
            prefixes = unique
            return unique
        }
    }
}
