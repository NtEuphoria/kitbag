// Kitbag — an Arma 3 mod manager for macOS.
import AppKit
import SwiftUI

// MARK: - Models

struct Mod: Identifiable, Hashable {
    enum Source: String { case workshop = "Workshop", local = "Local", custom = "Custom" }
    var id: String { path }
    let name: String
    let path: String
    let source: Source
    var workshopID: String? { source == .workshop ? URL(fileURLWithPath: path).lastPathComponent : nil }
}

struct Playset: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var mods: [String] = []   // mod paths
}

struct PerfSettings: Codable, Equatable {
    var skipIntro = true
    var noSplash = true
    var emptyWorld = true
    var noLogs = false
    // No -hugePages: it segfaults the macOS build at launch.
    var enableHT = false
    var useAllCores = false
    var exThreads = false
    var customParams = ""

    static let maxFPS = PerfSettings(skipIntro: true, noSplash: true, emptyWorld: true, noLogs: true,
                                     enableHT: true, useAllCores: true, exThreads: true)
    static let balanced = PerfSettings()

    var arguments: [String] {
        var a: [String] = []
        if skipIntro { a.append("-skipIntro") }
        if noSplash { a.append("-noSplash") }
        if emptyWorld { a.append("-world=empty") }
        if noLogs { a.append("-noLogs") }
        if enableHT { a.append("-enableHT") }
        if useAllCores { a.append("-cpuCount=\(ProcessInfo.processInfo.activeProcessorCount)") }
        if exThreads { a.append("-exThreads=7") }
        a += customParams.split(separator: " ").map(String.init)
        return a
    }
}

struct SavedState: Codable {
    var playsets: [Playset]
    var activePlayset: UUID?
    var perf: PerfSettings
    var extraFolders: [String]
    var workshopOnline: Bool?   // optional so state saved by older versions still decodes
    var gameBuild: String?      // raw value, so a build name this version doesn't know can't fail the whole decode
    var nativeCrashed: String?  // fingerprint of the Apple Silicon build that last crashed while starting
}

// MARK: - Scanning

enum Scanner {
    static let steamRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Steam")

    /// Every Steam library folder, read from libraryfolders.vdf (covers external drives).
    static func steamLibraries() -> [URL] {
        var libs = [steamRoot]
        let vdf = steamRoot.appendingPathComponent("steamapps/libraryfolders.vdf")
        if let text = try? String(contentsOf: vdf, encoding: .utf8) {
            let re = try! NSRegularExpression(pattern: #""path"\s+"([^"]+)""#)
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let r = Range(m.range(at: 1), in: text) {
                    let u = URL(fileURLWithPath: String(text[r]))
                    if !libs.contains(where: { $0.standardizedFileURL == u.standardizedFileURL }) { libs.append(u) }
                }
            }
        }
        return libs
    }

    static func gameFolder() -> URL? {
        steamLibraries().map { $0.appendingPathComponent("steamapps/common/Arma 3") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func detectedLocations() -> [URL] {
        var out: [URL] = []
        for lib in steamLibraries() {
            let ws = lib.appendingPathComponent("steamapps/workshop/content/107410")
            if FileManager.default.fileExists(atPath: ws.path) { out.append(ws) }
        }
        if let g = gameFolder() { out.append(g) }
        return out
    }

    static func modName(_ folder: URL) -> String {
        for f in ["meta.cpp", "mod.cpp"] {
            let url = folder.appendingPathComponent(f)
            if let t = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)),
               let r = t.range(of: #"name\s*=\s*"([^"]+)""#, options: .regularExpression) {
                let s = t[r]
                if let q1 = s.firstIndex(of: "\""), let q2 = s.lastIndex(of: "\""), q1 < q2 {
                    return String(s[s.index(after: q1)..<q2])
                }
            }
        }
        return folder.lastPathComponent
    }

    static func scan(extra: [String]) -> [Mod] {
        let fm = FileManager.default
        var mods: [Mod] = []
        func subdirs(_ u: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        for lib in steamLibraries() {
            for d in subdirs(lib.appendingPathComponent("steamapps/workshop/content/107410")) {
                mods.append(Mod(name: modName(d), path: d.path, source: .workshop))
            }
        }
        if let g = gameFolder() {
            for d in subdirs(g) where d.lastPathComponent.hasPrefix("@") {
                mods.append(Mod(name: modName(d), path: d.path, source: .local))
            }
        }
        for e in extra {
            for d in subdirs(URL(fileURLWithPath: e)) where d.lastPathComponent.hasPrefix("@") {
                mods.append(Mod(name: modName(d), path: d.path, source: .custom))
            }
        }
        return mods.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    @Published var mods: [Mod] = []
    @Published var playsets: [Playset] = [] { didSet { refreshIssues() } }
    @Published var activeID: UUID? { didSet { refreshIssues() } }
    @Published var perf = PerfSettings()
    @Published var extraFolders: [String] = []
    @Published var scanning = false
    @Published var toast: String?

    // Health checks
    @Published var index: HealthIndex? { didSet { refreshIssues() } }
    /// Fetch Workshop details (removed items, Required items) from Steam. Sends only Workshop IDs.
    @Published var workshopOnline = true { didSet { save(); if workshopOnline { fetchWorkshop() } } }

    nonisolated static let logsFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Kitbag/Logs")
    @Published private(set) var issues: [Issue] = []
    @Published private(set) var modSeverity: [String: Issue.Severity] = [:]
    @Published var lastCrash: CrashInfo? { didSet { refreshIssues() } }
    @Published var launchWarningPending = false

    // Game build
    @Published var gameBuild = GameBuild.automatic { didSet { save() } }
    @Published private(set) var nativeSupport = NativeSupport.notInstalled
    @Published private var nativeCrashed: String?
    @Published private var nativeFingerprint: String?
    private var waitingForSteam = false
    private var steamWaitBuild: GameBuild?
    /// The build a Play asked for, kept while the playset warning is up so "Play Anyway" uses it too.
    private(set) var playBuild: GameBuild?
    private var session: (pid: pid_t, build: GameBuild, fingerprint: String?, privateCache: Bool, stoppedForSteam: Bool)?

    var problemCount: Int { issues.filter { $0.severity >= .warning }.count }
    /// Errors tied to specific mods (excludes the "last launch crashed" notice).
    var modErrorCount: Int { issues.filter { $0.severity == .error && !$0.mods.isEmpty }.count }

    private let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kitbag")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }()

    init() {
        if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(SavedState.self, from: d) {
            playsets = s.playsets; activeID = s.activePlayset; perf = s.perf; extraFolders = s.extraFolders
            workshopOnline = s.workshopOnline ?? true
            gameBuild = s.gameBuild.flatMap(GameBuild.init(rawValue:)) ?? .automatic; nativeCrashed = s.nativeCrashed
        }
        if playsets.isEmpty { playsets = [Playset(name: "Vanilla+")] }
        if activeID == nil || !playsets.contains(where: { $0.id == activeID }) { activeID = playsets[0].id }
        refreshBuildInfo()
        rescan()
    }

    func save() {
        let s = SavedState(playsets: playsets, activePlayset: activeID, perf: perf, extraFolders: extraFolders,
                           workshopOnline: workshopOnline, gameBuild: gameBuild.rawValue, nativeCrashed: nativeCrashed)
        try? JSONEncoder().encode(s).write(to: file)
    }

    func rescan() {
        scanning = true
        let extra = extraFolders
        Task.detached {
            let found = Scanner.scan(extra: extra)
            await MainActor.run { self.mods = found; self.scanning = false; self.refreshBuildInfo() }
            var index = HealthIndex.build(mods: found, gameFolder: Scanner.gameFolder())
            if let last = GameLog.archivedLogs(in: Store.logsFolder).max(by: { Store.modified($0) < Store.modified($1) }) {
                index.lastSession = GameLog.load(last, modFolders: found.map(\.path),
                                                 aliases: Store.modLinks(in: Scanner.gameFolder()))
            }
            let built = index
            await MainActor.run { self.index = built; self.fetchWorkshop() }
        }
    }

    /// Online Workshop details, cached by WorkshopService for a day. Refreshes issues when they arrive.
    func fetchWorkshop() {
        guard workshopOnline, index != nil else { return }
        let ids = mods.compactMap(\.workshopID)
        Task {
            let info = await WorkshopService.shared.details(for: ids)
            // Mods whose files carry no name show their Workshop ID; use the Workshop title instead.
            let renamed = mods.map { m -> Mod in
                guard let id = m.workshopID, m.name == id, let title = info[id]?.title, !title.isEmpty else { return m }
                return Mod(name: title, path: m.path, source: m.source)
            }
            if renamed != mods {
                mods = renamed.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
            self.index?.online = info
        }
    }

    private nonisolated static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    func refreshIssues() {
        guard let index else { issues = []; modSeverity = [:]; return }
        var list = Health.analyze(enabled: mods.filter(isOn), all: mods, index: index)
        if let crash = lastCrash { list.insert(crash.issue, at: 0) }
        issues = list
        var sev: [String: Issue.Severity] = [:]
        for i in list { for p in i.mods { sev[p] = max(sev[p] ?? .info, i.severity) } }
        modSeverity = sev
    }

    func apply(_ fix: Issue.Fix) {
        guard let i = activeIndex else { return }
        switch fix {
        case .enable(let paths): playsets[i].mods += paths.filter { !playsets[i].mods.contains($0) }
        case .disable(let paths): playsets[i].mods.removeAll { paths.contains($0) }
        }
        save()
    }

    func fixAll() {
        // Enable missing dependencies first, then re-analyze, so disables don't drop mods a fix just needed.
        for issue in issues { if case .enable? = issue.fix { apply(issue.fix!) } }
        for issue in issues where issue.severity >= .warning { if case .disable? = issue.fix { apply(issue.fix!) } }
    }

    /// Play button entry point: warn first when the playset has errors that are likely to crash.
    func play(using build: GameBuild? = nil) {
        playBuild = build
        if modErrorCount > 0 { launchWarningPending = true } else { launch(using: build) }
    }

    var activeIndex: Int? { playsets.firstIndex { $0.id == activeID } }
    var active: Playset? { activeIndex.map { playsets[$0] } }

    func isOn(_ m: Mod) -> Bool { active?.mods.contains(m.path) ?? false }

    func toggle(_ m: Mod) { set(m, !isOn(m)) }

    func set(_ m: Mod, _ on: Bool) {
        guard let i = activeIndex else { return }
        playsets[i].mods.removeAll { $0 == m.path }
        if on { playsets[i].mods.append(m.path) }
        save()
    }

    func setAll(_ list: [Mod], _ on: Bool) {
        guard let i = activeIndex else { return }
        let paths = Set(list.map(\.path))
        playsets[i].mods.removeAll { paths.contains($0) }
        if on { playsets[i].mods += list.map(\.path) }
        save()
    }

    func newPlayset() {
        let p = Playset(name: "New Playset \(playsets.count + 1)")
        playsets.append(p); activeID = p.id; save()
    }

    func duplicate(_ p: Playset) {
        var c = p; c.id = UUID(); c.name += " Copy"
        playsets.append(c); activeID = c.id; save()
    }

    func delete(_ p: Playset) {
        guard playsets.count > 1 else { return }
        playsets.removeAll { $0.id == p.id }
        if activeID == p.id { activeID = playsets.first?.id }
        save()
    }

    /// Enabled mods in launch order: frameworks first, compat patches last.
    var launchOrder: [Mod] {
        let on = mods.filter(isOn)
        let first = ["cba", "ace", "task force", "tfar", "acre", "rhs", "cup"]
        func rank(_ m: Mod) -> Int {
            let n = m.name.lowercased()
            if n.contains("compat") { return 100 }
            return first.firstIndex { n.contains($0) } ?? 50
        }
        return on.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    var missingCount: Int {
        guard let a = active else { return 0 }
        let have = Set(mods.map(\.path))
        return a.mods.filter { !have.contains($0) }.count
    }

    /// Cheap (a stat and a ~2 ms scan of the game binary), so it runs again before every launch.
    func refreshBuildInfo() {
        guard let game = Scanner.gameFolder() else {
            nativeSupport = NativeCheck.isAppleSilicon ? .notInstalled : .unavailable("This Mac has an Intel processor.")
            nativeFingerprint = nil
            return
        }
        let support = NativeCheck.support(in: game)
        if support != nativeSupport { nativeSupport = support }
        let fingerprint = NativeCheck.fingerprint(of: GameBuild.native.executable(in: game))
        if fingerprint != nativeFingerprint { nativeFingerprint = fingerprint }
    }

    /// Whether the build choice means anything here: only Apple Silicon Macs have two builds to pick from.
    var hasBuildChoice: Bool { NativeCheck.isAppleSilicon }

    var nativeCrashedBefore: Bool { nativeCrashed != nil && nativeCrashed == nativeFingerprint }

    /// The build Play starts: .native or .rosetta. Automatic never relies on the experimental
    /// private-cache workaround: with it the Apple Silicon build starts but crashed within minutes in testing.
    var plannedBuild: GameBuild {
        switch gameBuild {
        case .native: return nativeSupport.canRun ? .native : .rosetta
        case .rosetta: return .rosetta
        case .automatic: return nativeSupport == .supported && !nativeCrashedBefore ? .native : .rosetta
        }
    }

    /// Which build Play starts and why, shown under the Game build picker and on the footer label.
    var buildNote: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        switch (gameBuild, nativeSupport) {
        case (.rosetta, _):
            return "Always starts the Intel build through Rosetta."
        case (_, .unavailable(let why)):
            return "\(why) Play starts the Intel build."
        case (_, .notInstalled):
            return "The Apple Silicon build isn't installed, so Play starts the Intel build through Rosetta."
        case (.native, .needsPrivateCache):
            return "Experimental. On macOS \(os) the Apple Silicon build can't start normally, so Kitbag starts it with its own copy of the system libraries. It then gets as far as drawing the game, but it crashed within five minutes in testing."
        case (.native, _):
            return "Always starts the Apple Silicon build." + (nativeCrashedBefore ? " It crashed while starting the last time Kitbag ran it." : "")
        case (.automatic, .needsPrivateCache):
            return "Starts the Intel build through Rosetta. The Apple Silicon build can't start normally on macOS \(os). Choose Apple Silicon to try Kitbag's experimental workaround for it."
        case (.automatic, _):
            if nativeCrashedBefore {
                return "Starts the Intel build through Rosetta: the Apple Silicon build crashed while starting the last time Kitbag ran it. Kitbag tries it again after the Apple Silicon build or macOS is updated."
            }
            return "Starts the Apple Silicon build. If it crashes while starting, Play uses the Intel build (Rosetta) until the Apple Silicon build or macOS is updated."
        }
    }

    func launch(using forced: GameBuild? = nil, waitedForSteam: Bool = false) {
        if let s = session, kill(s.pid, 0) == 0 {
            flash("Arma 3 is already running"); bringToFront(pid: s.pid); return
        }
        if waitingForSteam && !waitedForSteam {
            steamWaitBuild = forced
            flash("Waiting for Steam to sign in — Arma 3 launches when it's ready"); return
        }
        let order = launchOrder
        var args = perf.arguments
        // Steam's -applaunch only focuses an already-running Steam on macOS and drops the
        // arguments, so start the game binary directly. steam_appid.txt in the game folder
        // lets it attach to the running Steam client without being relaunched through Steam.
        guard let game = Scanner.gameFolder() else { flash("Couldn't find Arma 3 in your Steam library"); return }
        refreshBuildInfo()
        let wanted = forced ?? plannedBuild
        // Fall back to the other build only when it can run: never from Intel to an Apple Silicon build that can't.
        let candidates: [GameBuild] = wanted == .native ? [.native, .rosetta]
            : forced == nil && nativeSupport.canRun ? [.rosetta, .native] : [.rosetta]
        guard let build = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.executable(in: game).path) }) else {
            flash("Couldn't find \(wanted.appName).app in \(game.path)"); return
        }
        guard waitedForSteam || Store.steamIsReady else { waitForSteam(then: forced); return }
        if !order.isEmpty {
            guard let modArg = Store.modArgument(order.map(\.path), in: game) else {
                flash("Couldn't link your mods into the Arma 3 folder. Check that Kitbag can write to it."); return
            }
            args.append(modArg)
        }
        // Both game apps share the bundle ID com.vpltd.Arma3, so opening either .app through
        // LaunchServices can resolve to the Intel build. Exec the chosen binary directly to
        // guarantee which one runs, then bring it to the front ourselves.
        let p = Process()
        p.executableURL = build.executable(in: game)
        p.currentDirectoryURL = game
        p.arguments = args
        let privateCache = build == .native && nativeSupport == .needsPrivateCache
        if privateCache {
            var env = ProcessInfo.processInfo.environment
            env["DYLD_SHARED_REGION"] = "private"   // see NativeCheck.support
            p.environment = env
        }
        // A file rather than a pipe: the game keeps writing after Kitbag quits, and a closed pipe would kill it.
        let output = Store.logsFolder.deletingLastPathComponent().appendingPathComponent("game-output.txt")
        if FileManager.default.createFile(atPath: output.path, contents: nil), let h = try? FileHandle(forWritingTo: output) {
            p.standardOutput = h; p.standardError = h
        }
        let started = Date()
        let launched = order.map(\.path)
        p.terminationHandler = { proc in
            let crashed = proc.terminationReason == .uncaughtSignal
            let pid = proc.processIdentifier, exited = Date()
            Task { @MainActor in await self.gameExited(pid: pid, started: started, exited: exited, crashed: crashed, mods: launched) }
        }
        do { try p.run() } catch {
            let rosettaMissing = (error as NSError).code == Int(EBADARCH)
            flash(rosettaMissing ? "Rosetta isn't installed. Open ArmA3.app from Finder once to install it."
                                 : "Couldn't start Arma 3: \(error.localizedDescription)")
            return
        }
        session = (p.processIdentifier, build, build == .native ? nativeFingerprint : nil, privateCache, false)
        lastCrash = nil
        let which = build == .native ? " (Apple Silicon)" : " (Intel)"
        flash("Launching Arma 3\(which) with \(order.count) mod\(order.count == 1 ? "" : "s")…")
        bringToFront(pid: p.processIdentifier)
        watchForSteamFailure(pid: p.processIdentifier, output: output)
    }

    /// Opens Steam if needed and launches once it's up, instead of asking for a second click.
    private func waitForSteam(then forced: GameBuild?) {
        waitingForSteam = true
        steamWaitBuild = forced
        if !Store.steamIsRunning { NSWorkspace.shared.open(URL(string: "steam://open/main")!) }
        flash("Waiting for Steam to sign in — Arma 3 launches when it's ready")
        Task {
            for second in 1...120 {
                try? await Task.sleep(for: .seconds(1))
                // Offline mode never reaches "Logged On", so after a minute with Steam up, try anyway.
                if Store.steamIsReady || (second >= 60 && Store.steamPIDAlive) {
                    try? await Task.sleep(for: .seconds(2))
                    waitingForSteam = false
                    launch(using: steamWaitBuild, waitedForSteam: true)
                    return
                }
            }
            waitingForSteam = false
            flash("Steam didn't start. Open it, sign in, then press Play.")
        }
    }

    /// Without a signed-in Steam the game prints this and then hangs instead of quitting.
    private func watchForSteamFailure(pid: pid_t, output: URL) {
        let needle = Data("Steam Client is not running".utf8)
        Task {
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(1))
                guard session?.pid == pid else { return }
                guard let h = try? FileHandle(forReadingFrom: output) else { continue }
                let data = (try? h.read(upToCount: 1 << 20)) ?? Data()
                try? h.close()
                guard data.range(of: needle) != nil else { continue }
                session?.stoppedForSteam = true
                kill(pid, SIGTERM)
                try? await Task.sleep(for: .seconds(3))
                if session?.pid == pid { kill(pid, SIGKILL) }
                return
            }
        }
    }

    /// Keeps the session's game log (the next launch overwrites it) and reads it for evidence, then
    /// waits briefly for a crash report: macOS writes the .ips a moment after the process dies.
    private func gameExited(pid: pid_t, started: Date, exited: Date, crashed: Bool, mods: [String]) async {
        let ended = session?.pid == pid ? session : nil
        if ended != nil { session = nil }
        if ended?.stoppedForSteam == true {
            flash("Arma 3 couldn't reach Steam. Make sure you're signed in, then press Play.")
            NSApp.activate()
            return
        }
        // Eon logs the game executable once it has loaded it. A crash before that is the Apple Silicon
        // wrapper failing to start, not a mod: remember it now, before the slower log and report steps,
        // so Automatic uses the Intel build even if Play is pressed again right away.
        let gameLoaded = (try? Data(contentsOf: GameLog.defaultURL))
            .map { $0.range(of: Data("Arma3Retail_DX11_x64.exe loaded".utf8)) != nil } ?? true
        let nativeStartupFailure = crashed && ended?.build == .native && !gameLoaded
        if nativeStartupFailure { nativeCrashed = ended?.fingerprint ?? nativeFingerprint; save() }
        if let saved = GameLog.archiveCurrentLog(to: Store.logsFolder) {
            index?.lastSession = GameLog.load(saved, modFolders: mods, aliases: Store.modLinks(in: Scanner.gameFolder()))
        }
        var found: (URL, String?)?
        for _ in 0..<10 {
            found = CrashInfo.find(since: started)
            if found != nil || !crashed { break }
            try? await Task.sleep(for: .seconds(1))
        }
        guard crashed || found != nil else { return }
        let seconds = exited.timeIntervalSince(started)
        var info = CrashInfo(secondsAfterLaunch: seconds, report: found?.0, culprit: found?.1)
        let toPlay = "To play now, click Play with Intel Build in the main window, or set Game build to Automatic or Intel (Rosetta) in Performance."
        if nativeStartupFailure {
            let next = gameBuild == .native ? toPlay : "Play now uses the Intel build (Rosetta) until the Apple Silicon build or macOS is updated."
            info.nativeFailure = ("The Apple Silicon build crashed while starting",
                                  "It closed \(Int(seconds)) s after launch, before Arma 3 itself had loaded, so your mods aren't the cause. \(next)")
        } else if ended?.privateCache == true {
            let os = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
            info.nativeFailure = ("The experimental Apple Silicon build crashed",
                                  "It was running with Kitbag's macOS \(os) workaround, which crashed within five minutes in testing even with no mods, so this isn't necessarily a mod problem. \(toPlay)")
        }
        lastCrash = info
        NSApp.activate()
    }

    /// The game opens its window well after exec, and macOS 14+ only lets an app take focus
    /// when the frontmost app yields it. Keep yielding and activating until it sticks (~30 s).
    private func bringToFront(pid: pid_t, attempts: Int = 60) {
        Task {
            for _ in 0..<attempts {
                if let app = NSRunningApplication(processIdentifier: pid) {
                    if app.isTerminated || app.isActive { return }
                    NSApp.yieldActivation(to: app)
                    app.activate()
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    nonisolated static let modLinkFolder = "!Kitbag"

    /// Both Arma builds crash as their window opens when -mod lists long absolute paths: 114 Workshop
    /// mods (11,000+ characters) failed every time, while the same mods as short links ran fine. Like
    /// the official launcher's !Workshop folder, link each mod into the game folder as !Kitbag/<n> and
    /// pass those short relative paths. Nil if the links can't be made.
    static func modArgument(_ paths: [String], in game: URL) -> String? {
        let fm = FileManager.default
        do {
            // Rebuilt every launch so links from an older playset don't linger. Only symlinks are removed.
            for link in modLinks(in: game).keys { try fm.removeItem(at: game.appendingPathComponent(link)) }
            try fm.createDirectory(at: game.appendingPathComponent(modLinkFolder), withIntermediateDirectories: true)
            var names: [String] = []
            for (i, path) in paths.enumerated() {
                let name = "\(modLinkFolder)/\(i + 1)"
                try fm.createSymbolicLink(atPath: game.appendingPathComponent(name).path, withDestinationPath: path)
                names.append(name)
            }
            return "-mod=" + names.joined(separator: ";")
        } catch {
            return nil
        }
    }

    /// The links from the last launch, "!Kitbag/<n>" → the mod folder each points to, so the game log's
    /// paths can be traced back to mods.
    nonisolated static func modLinks(in game: URL?) -> [String: String] {
        guard let game else { return [:] }
        let fm = FileManager.default
        let dir = game.appendingPathComponent(modLinkFolder)
        var links: [String: String] = [:]
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            if let target = try? fm.destinationOfSymbolicLink(atPath: dir.appendingPathComponent(name).path) {
                links["\(modLinkFolder)/\(name)"] = target
            }
        }
        return links
    }

    static var steamIsRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.executableURL?.lastPathComponent == "steam_osx" || $0.bundleIdentifier == "com.valvesoftware.steam"
        }
    }

    /// Started before Steam signs in, the game prints "Steam Client is not running" and hangs.
    static var steamIsReady: Bool { steamPIDAlive && steamSignedIn }

    /// The game's steam_api finds Steam through the SteamPID that Steam writes to registry.vdf as it
    /// starts, so check the same thing. Falls back to the process check if the key is absent.
    static var steamPIDAlive: Bool {
        let vdf = Scanner.steamRoot.appendingPathComponent("registry.vdf")
        guard let text = try? String(contentsOf: vdf, encoding: .utf8),
              let m = try! NSRegularExpression(pattern: #""SteamPID"\s+"(\d+)""#)
                .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text), let pid = Int32(text[r]) else { return steamIsRunning }
        return pid > 0 && kill(pid, 0) == 0
    }

    /// Steam logs each connection state as "[time] [Logged On, …]"; the latest one is the current state.
    static var steamSignedIn: Bool {
        let log = Scanner.steamRoot.appendingPathComponent("logs/connection_log.txt")
        guard let h = try? FileHandle(forReadingFrom: log) else { return true }   // no log to go by: don't block
        defer { try? h.close() }
        let end = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: end > 32_768 ? end - 32_768 : 0)
        guard let data = try? h.readToEnd() else { return true }
        let tail = String(decoding: data, as: UTF8.self)   // lossy: the seek can land mid-character
        let re = try! NSRegularExpression(pattern: #"\] \[(Logged On|Logged Off|Logging On|Logging Off|Connecting|Connected|Disconnected)[,\]]"#)
        guard let last = re.matches(in: tail, range: NSRange(tail.startIndex..., in: tail)).last,
              let r = Range(last.range(at: 1), in: tail) else { return true }
        return tail[r] == "Logged On"
    }

    func flash(_ s: String) {
        withAnimation { toast = s }
        Task { try? await Task.sleep(for: .seconds(3)); withAnimation { if toast == s { toast = nil } } }
    }
}

// MARK: - Theme

extension Color {
    static let kbAccent = Color(red: 0.54, green: 0.68, blue: 0.33)   // olive drab
}

// MARK: - Views

enum Filter: String, CaseIterable { case all = "All", enabled = "Enabled", disabled = "Disabled" }

/// View-local state. Uses ObservableObject rather than @State: the @State macro's
/// plugin ships only with full Xcode, and this builds with the Command Line Tools.
final class ContentUI: ObservableObject {
    @Published var search = ""
    @Published var filter = Filter.all
    @Published var showPerf = false
    @Published var showLocations = false
    @Published var showHealth = false
    @Published var renaming: Playset?
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @StateObject private var ui = ContentUI()

    private var search: String { ui.search }
    private var filter: Filter { ui.filter }

    var visible: [Mod] {
        store.mods.filter { m in
            (search.isEmpty || m.name.localizedCaseInsensitiveContains(search)) &&
            (filter == .all || (filter == .enabled) == store.isOn(m))
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            VStack(spacing: 0) {
                header
                if store.lastCrash != nil { crashBanner }
                Divider()
                modList
                Divider()
                footer
            }
            .overlay(alignment: .top) { toastView }
        }
        .tint(.kbAccent)
        .searchable(text: $ui.search, placement: .toolbar, prompt: "Search mods")
        .toolbar {
            ToolbarItemGroup {
                Button { store.rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .help("Rescan mod folders")
                Button { ui.showLocations = true } label: { Label("Locations", systemImage: "folder") }
                    .help("Mod locations")
                Button { ui.showPerf = true } label: { Label("Performance", systemImage: "gauge.with.dots.needle.67percent") }
                    .help("Performance settings")
                Button { ui.showHealth = true } label: {
                    Label("Health Check", systemImage: store.problemCount > 0 ? "stethoscope.circle.fill" : "stethoscope")
                }
                .badge(store.problemCount)
                .help(store.problemCount > 0 ? "\(store.problemCount) problem(s) in this playset" : "Health check: no problems found")
            }
        }
        .sheet(isPresented: $ui.showHealth) { HealthView().environmentObject(store) }
        .alert("This playset has \(store.modErrorCount) problem\(store.modErrorCount == 1 ? "" : "s")",
               isPresented: $store.launchWarningPending) {
            Button("Review Problems") { ui.showHealth = true }
            Button("Play Anyway") { store.launch(using: store.playBuild) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Missing dependencies and conflicts are common causes of errors and crashes in Arma 3.")
        }
        .sheet(isPresented: $ui.showPerf) { PerformanceView().environmentObject(store) }
        .sheet(isPresented: $ui.showLocations) { LocationsView().environmentObject(store) }
        .sheet(item: $ui.renaming) { p in RenameView(playset: p).environmentObject(store) }
    }

    var sidebar: some View {
        List(selection: Binding(get: { store.activeID }, set: { store.activeID = $0; store.save() })) {
            Section("Playsets") {
                ForEach(store.playsets) { p in
                    HStack {
                        Image(systemName: "shippingbox.fill").foregroundStyle(Color.kbAccent)
                        Text(p.name).lineLimit(1)
                        Spacer()
                        Text("\(p.mods.count)").font(.caption.monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    .tag(p.id)
                    .contextMenu {
                        Button("Rename…") { ui.renaming = p }
                        Button("Duplicate") { store.duplicate(p) }
                        Divider()
                        Button("Delete", role: .destructive) { store.delete(p) }
                            .disabled(store.playsets.count == 1)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button { store.newPlayset() } label: {
                Label("New Playset", systemImage: "plus.circle.fill").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain).padding(12)
        }
    }

    var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.active?.name ?? "").font(.title2.weight(.semibold))
                Text("\(store.active?.mods.count ?? 0) of \(store.mods.count) mods enabled")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if store.missingCount > 0 {
                Label("\(store.missingCount) missing", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .help("Mods in this playset that are no longer installed")
            }
            Spacer()
            Picker("", selection: $ui.filter) {
                ForEach(Filter.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented).frame(width: 220).labelsHidden()
            Menu {
                Button("Enable all shown") { store.setAll(visible, true) }
                Button("Disable all shown") { store.setAll(visible, false) }
            } label: { Image(systemName: "checklist") }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    @ViewBuilder var modList: some View {
        if store.scanning && store.mods.isEmpty {
            ProgressView("Scanning for mods…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.mods.isEmpty {
            ContentUnavailableView {
                Label("No mods found", systemImage: "shippingbox")
            } description: {
                Text("Subscribe to mods on the Steam Workshop, or add a folder containing @mods.")
            } actions: {
                Button("Add Mod Folder…") { ui.showLocations = true }
            }
        } else if visible.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            List(visible) { m in ModRow(mod: m) }
                .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    var footer: some View {
        HStack(spacing: 12) {
            Button { ui.showPerf = true } label: {
                Label(store.perf == .maxFPS ? "Max FPS" : "\(store.perf.arguments.count) launch options",
                      systemImage: "gauge.with.dots.needle.67percent").lineLimit(1)
            }
            .buttonStyle(.link).help("Performance settings")
            if store.hasBuildChoice {
                Divider().frame(height: 16)
                Label(store.plannedBuild == .native ? "Apple Silicon" : "Intel", systemImage: "cpu")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    .help(store.buildNote)
            }
            Spacer(minLength: 8)
            healthPill.fixedSize()
            Button { store.play() } label: {
                Label("Play Arma 3", systemImage: "play.fill")
                    .font(.headline).padding(.horizontal, 18).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).fixedSize()
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.bar)
    }

    /// Footer status: green when clean, orange/red with a count otherwise. Opens the Health panel.
    var healthPill: some View {
        let errors = store.issues.filter { $0.severity == .error }.count
        let (icon, color, text): (String, Color, String) =
            store.index == nil ? ("hourglass", .secondary, "Checking…")
            : errors > 0 ? ("xmark.octagon.fill", .red, "\(errors) error\(errors == 1 ? "" : "s")")
            : store.problemCount > 0 ? ("exclamationmark.triangle.fill", .orange, "\(store.problemCount) warning\(store.problemCount == 1 ? "" : "s")")
            : ("checkmark.seal.fill", .kbAccent, "No problems")
        return Button { ui.showHealth = true } label: {
            Label(text, systemImage: icon).font(.callout.weight(.medium)).foregroundStyle(color)
        }
        .buttonStyle(.plain).help("Open Health Check")
    }

    var crashBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.trianglebadge.exclamationmark.fill").foregroundStyle(.red).font(.title3)
            Text(store.lastCrash?.issue.title ?? "").font(.callout.weight(.semibold))
            Spacer()
            if store.lastCrash?.nativeFailure != nil {
                Button("Play with Intel Build") { store.play(using: .rosetta) }
            }
            Button("See Why") { ui.showHealth = true }
            Button { store.lastCrash = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(Color.red.opacity(0.12))
    }

    @ViewBuilder var toastView: some View {
        if let t = store.toast {
            Text(t).font(.callout.weight(.medium))
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 6, y: 2).padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

struct ModRow: View {
    @EnvironmentObject var store: Store
    let mod: Mod

    var body: some View {
        let on = store.isOn(mod)
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { on }, set: { store.set(mod, $0) }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text(mod.name).fontWeight(on ? .medium : .regular)
                    .foregroundStyle(on ? .primary : .secondary)
                Text(mod.workshopID.map { "Workshop · \($0)" } ?? mod.source.rawValue)
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            if let sev = store.modSeverity[mod.path], sev >= .warning {
                Image(systemName: sev == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(sev == .error ? .red : .orange)
                    .help(store.issues.first { $0.mods.contains(mod.path) }?.title ?? "")
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { store.toggle(mod) }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: mod.path) }
            if let id = mod.workshopID {
                Button("Open Workshop Page") {
                    NSWorkspace.shared.open(URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)")!)
                }
            }
        }
    }
}

struct PerformanceView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Performance").font(.title2.weight(.semibold))
                Text("Launch options that help Arma 3 load faster and run smoother.")
                    .foregroundStyle(.secondary)
            }.padding(20)

            HStack(spacing: 12) {
                profileCard("Balanced", "Safe defaults", "leaf.fill", .balanced)
                profileCard("Max FPS", "Every optimization on", "bolt.fill", .maxFPS)
            }.padding(.horizontal, 20)

            Form {
                if store.hasBuildChoice {
                    Section("Game build") {
                        Picker("Build", selection: $store.gameBuild) {
                            ForEach(GameBuild.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        Text(store.buildNote).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Section("Startup") {
                    opt("Skip intro video", "-skipIntro", \.skipIntro)
                    opt("Skip splash screens", "-noSplash", \.noSplash)
                    opt("Empty main-menu world", "-world=empty · faster loading, less RAM", \.emptyWorld)
                }
                Section("Engine") {
                    opt("Use all CPU cores", "-cpuCount=\(ProcessInfo.processInfo.activeProcessorCount)", \.useAllCores)
                    opt("Extra worker threads", "-exThreads=7 · geometry, texture & file loading", \.exThreads)
                    opt("Hyper-threading", "-enableHT", \.enableHT)
                    opt("Disable logging", "-noLogs · less disk writing, but no crash logs", \.noLogs)
                }
                Section("Custom") {
                    TextField("Extra parameters", text: $store.perf.customParams, prompt: Text("-name=Player -nosound"))
                }
                Section {
                    DisclosureGroup("In-game tips for more FPS") {
                        VStack(alignment: .leading, spacing: 6) {
                            tip("View distance is the biggest FPS cost — try 1500–2500 m.")
                            tip("Shadows: Standard or Low. Turn off PPAA and SSAO.")
                            tip("Terrain: Standard or Low. Clouds: Low.")
                            tip("Fewer mods = less RAM and faster loading. Keep a lean playset for public servers.")
                            tip("Arma is CPU-limited: in multiplayer, server FPS caps yours too.")
                        }.padding(.vertical, 4)
                    }
                }
            }
            .formStyle(.grouped)
            .onChange(of: store.perf) { store.save() }

            HStack {
                Text("Effects vary on macOS; some options mainly help on high-core-count Macs.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(20)
        }
        .frame(width: 540, height: 760)
    }

    func profileCard(_ title: String, _ sub: String, _ icon: String, _ p: PerfSettings) -> some View {
        let selected = store.perf == p
        return Button { withAnimation { store.perf = p } } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.title2).foregroundStyle(selected ? .white : Color.kbAccent)
                VStack(alignment: .leading) {
                    Text(title).font(.headline)
                    Text(sub).font(.caption).opacity(0.8)
                }
                Spacer()
            }
            .padding(14).frame(maxWidth: .infinity)
            .foregroundStyle(selected ? .white : .primary)
            .background(selected ? Color.kbAccent : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }

    func opt(_ title: String, _ detail: String, _ kp: WritableKeyPath<PerfSettings, Bool>) -> some View {
        Toggle(isOn: Binding(get: { store.perf[keyPath: kp] }, set: { store.perf[keyPath: kp] = $0 })) {
            Text(title)
            Text(detail).font(.caption.monospaced())
        }
    }

    func tip(_ s: String) -> some View {
        Label(s, systemImage: "lightbulb").font(.callout)
    }
}

struct LocationsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Mod Locations").font(.title2.weight(.semibold))
            GroupBox("Found automatically") {
                VStack(alignment: .leading, spacing: 6) {
                    let found = Scanner.detectedLocations()
                    if found.isEmpty { Text("Arma 3 not found in any Steam library.").foregroundStyle(.secondary) }
                    ForEach(found, id: \.self) { u in
                        Label(u.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.kbAccent).font(.callout).lineLimit(1).truncationMode(.middle)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
            GroupBox("Extra folders (containing @mod folders)") {
                VStack(alignment: .leading, spacing: 6) {
                    if store.extraFolders.isEmpty { Text("None").foregroundStyle(.secondary) }
                    ForEach(store.extraFolders, id: \.self) { f in
                        HStack {
                            Text(f).font(.callout).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { store.extraFolders.removeAll { $0 == f }; store.save(); store.rescan() } label: {
                                Image(systemName: "minus.circle.fill")
                            }.buttonStyle(.plain).foregroundStyle(.red)
                        }
                    }
                    Button("Add Folder…", action: addFolder)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 520)
    }

    func addFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false
        if p.runModal() == .OK, let u = p.url, !store.extraFolders.contains(u.path) {
            store.extraFolders.append(u.path); store.save(); store.rescan()
        }
    }
}

struct RenameView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let playset: Playset
    final class Draft: ObservableObject { @Published var name = "" }
    @StateObject private var draft = Draft()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Playset").font(.headline)
            TextField("Name", text: $draft.name).onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename", action: commit).keyboardShortcut(.defaultAction).disabled(draft.name.isEmpty)
            }
        }
        .padding(20).frame(width: 320)
        .onAppear { draft.name = playset.name }
    }

    func commit() {
        if let i = store.playsets.firstIndex(where: { $0.id == playset.id }), !draft.name.isEmpty {
            store.playsets[i].name = draft.name; store.save()
        }
        dismiss()
    }
}

struct HealthView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss

    var fixable: Int { store.issues.filter { $0.fix != nil && $0.severity >= .warning }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: summaryIcon).font(.system(size: 34)).foregroundStyle(summaryColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Health Check").font(.title2.weight(.semibold))
                    Text(summary).foregroundStyle(.secondary)
                }
                Spacer()
                if fixable > 1 {
                    Button("Fix All (\(fixable))") { store.fixAll() }.controlSize(.large)
                }
            }
            .padding(20)
            Divider()

            if store.index == nil {
                ProgressView("Reading mod files…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.issues.isEmpty {
                ContentUnavailableView("No problems found", systemImage: "checkmark.seal.fill",
                                       description: Text("All dependencies are enabled and no mods conflict."))
            } else {
                List {
                    ForEach(Issue.Category.allCases, id: \.self) { category in
                        let items = store.issues.filter { $0.category == category }
                        if !items.isEmpty {
                            Section("\(category.rawValue) (\(items.count))") {
                                ForEach(items) { issue in IssueRow(issue: issue) }
                            }
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }

            Divider()
            HStack(spacing: 12) {
                Toggle("Check Steam Workshop online", isOn: $store.workshopOnline)
                    .toggleStyle(.checkbox).font(.caption)
                    .help("Looks up removed items and each mod's Required items. Only Workshop IDs are sent to Steam.")
                Text("Reads each mod's configs, Steam's download records, signatures and your last game log.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 720, height: 640)
    }

    var errors: Int { store.issues.filter { $0.severity == .error }.count }
    var summaryIcon: String { errors > 0 ? "xmark.octagon.fill" : store.problemCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.seal.fill" }
    var summaryColor: Color { errors > 0 ? .red : store.problemCount > 0 ? .orange : .kbAccent }
    var summary: String {
        if store.index == nil { return "Checking \(store.active?.name ?? "playset")…" }
        let warnings = store.problemCount - errors
        if store.problemCount == 0 { return "\(store.active?.name ?? "This playset") looks good." }
        // The last-launch crash notice is an error but not a playset problem, so it's reported apart.
        let crashNote = store.lastCrash != nil ? "Arma 3 crashed on the last launch." : nil
        let playsetErrors = errors - (crashNote == nil ? 0 : 1)
        var parts: [String] = []
        if playsetErrors > 0 { parts.append("\(playsetErrors) error\(playsetErrors == 1 ? "" : "s") likely to cause crashes") }
        if warnings > 0 { parts.append("\(warnings) warning\(warnings == 1 ? "" : "s")") }
        if parts.isEmpty { return crashNote ?? "" }
        return ([crashNote].compactMap { $0 } + [parts.joined(separator: " and ") + " in \(store.active?.name ?? "this playset")."])
            .joined(separator: " ")
    }
}

struct IssueRow: View {
    @EnvironmentObject var store: Store
    let issue: Issue

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(color).font(.title3).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(issue.title).font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    if let c = issue.confidence, c < 0.75 {
                        Text("Likely").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule())
                            .help("Kitbag is fairly, but not fully, sure this causes problems in game.")
                    }
                }
                Text(issue.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !issue.evidence.isEmpty {
                    DisclosureGroup("Evidence") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(issue.evidence.prefix(8).enumerated()), id: \.offset) { _, line in
                                Text(line).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 2)
                    }
                    .font(.caption)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                if let fix = issue.fix {
                    Button(issue.fixLabel) { withAnimation { store.apply(fix) } }
                        .buttonStyle(.bordered).tint(color == .red ? .kbAccent : nil).lineLimit(1)
                } else if issue.category == .session, issue.mods.isEmpty, let report = store.lastCrash?.report {
                    Button("Crash Report") { NSWorkspace.shared.open(report) }.buttonStyle(.bordered)
                }
                if let link = issue.link {
                    Button(issue.linkLabel.isEmpty ? "Open" : issue.linkLabel) { NSWorkspace.shared.open(link) }
                        .buttonStyle(.link).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 6)
    }

    var icon: String {
        switch issue.severity {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }
    var color: Color {
        switch issue.severity {
        case .error: .red
        case .warning: .orange
        case .info: .blue
        }
    }
}

// MARK: - App

@main
struct KitbagApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup("Kitbag") {
            ContentView().environmentObject(store).frame(minWidth: 820, minHeight: 520)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Playset") { store.newPlayset() }.keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("Game") {
                Button("Play Arma 3") { store.play() }.keyboardShortcut(.return, modifiers: .command)
                Button("Rescan Mods") { store.rescan() }.keyboardShortcut("r")
            }
        }
    }
}
