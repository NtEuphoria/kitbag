// Headless run of the app's health pipeline (Health.swift) on the real library.
import Foundation

struct Mod { let name: String; let path: String
    var workshopID: String? { path.contains("/workshop/content/107410/") ? URL(fileURLWithPath: path).lastPathComponent : nil } }
enum Scanner {
    static let steamRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam")
    static func steamLibraries() -> [URL] { [steamRoot] }
}
let ws = Scanner.steamRoot.appendingPathComponent("steamapps/workshop/content/107410")
let game = Scanner.steamRoot.appendingPathComponent("steamapps/common/Arma 3")
let mods = try! FileManager.default.contentsOfDirectory(at: ws, includingPropertiesForKeys: nil).filter { !$0.lastPathComponent.hasPrefix(".") }.map { d -> Mod in
    let t = (try? String(contentsOf: d.appendingPathComponent("meta.cpp"), encoding: .utf8)) ?? ((try? String(contentsOf: d.appendingPathComponent("mod.cpp"), encoding: .utf8)) ?? "")
    let n = t.range(of: #"name\s*=\s*"[^"]+""#, options: .regularExpression).map { String(t[$0]).components(separatedBy: "\"")[1] } ?? d.lastPathComponent
    return Mod(name: n, path: d.path)
}
var t0 = Date()
var index = HealthIndex.build(mods: mods, gameFolder: game)
print(String(format: "HealthIndex.build: %.2fs for %d mods", Date().timeIntervalSince(t0), mods.count))
let sem = DispatchSemaphore(value: 0)
Task { index.online = await WorkshopService.shared.cached(mods.compactMap(\.workshopID)); sem.signal() }
sem.wait()
print("online cache entries:", index.online.count)
t0 = Date()
var enabled = mods
if let d = try? Data(contentsOf: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Kitbag/state.json")),
   let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], CommandLine.arguments.contains("--playset"),
   let sets = j["playsets"] as? [[String: Any]], let active = j["activePlayset"] as? String,
   let ps = sets.first(where: { ($0["id"] as? String) == active }), let paths = ps["mods"] as? [String] {
    enabled = mods.filter { paths.contains($0.path) }
    print("active playset:", ps["name"] ?? "", "with", enabled.count, "mods")
}
let issues = Health.analyze(enabled: enabled, all: mods, index: index)
print(String(format: "analyze (all enabled): %.1f ms, %d issues", Date().timeIntervalSince(t0) * 1000, issues.count))
for c in Issue.Category.allCases {
    let items = issues.filter { $0.category == c }
    guard !items.isEmpty else { continue }
    let sev = Dictionary(grouping: items, by: \.severity).map { "\($0.key): \($0.value.count)" }.sorted().joined(separator: ", ")
    print("\n## \(c.rawValue) — \(items.count) (\(sev))")
    for i in items.prefix(c == .multiplayer ? 3 : 12) { print("  [\(i.severity)] \(i.title)\(i.fixLabel.isEmpty ? "" : "  → \(i.fixLabel)")\(i.linkLabel.isEmpty ? "" : "  ⇢ \(i.linkLabel)")") }
}
