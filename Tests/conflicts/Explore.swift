// Exploration helpers: load the real library once and print census numbers used to design the analysis.
import Foundation

enum Lib {
    static let steam = "\(NSHomeDirectory())/Library/Application Support/Steam/steamapps"
    static let workshop = URL(fileURLWithPath: steam + "/workshop/content/107410")
    static let game = URL(fileURLWithPath: steam + "/common/Arma 3")

    static func modFolders() -> [URL] {
        let ids = ((try? FileManager.default.contentsOfDirectory(atPath: workshop.path)) ?? []).filter { Int($0) != nil }.sorted()
        return ids.map { workshop.appendingPathComponent($0) }
    }

    static func modName(_ dir: URL) -> String {
        for f in ["meta.cpp", "mod.cpp"] {
            if let t = (try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)) ?? (try? String(contentsOf: dir.appendingPathComponent(f), encoding: .isoLatin1)),
               let r = t.range(of: #"name\s*=\s*"([^"]*)""#, options: .regularExpression) {
                return String(t[r]).replacingOccurrences(of: #"^name\s*=\s*""#, with: "", options: .regularExpression).dropLast().description
            }
        }
        return dir.lastPathComponent
    }

    static func load() -> (GameIndex, [String: String]) {
        let t0 = Date()
        let idx = ConfigIndexer(cacheDirectory: ConfigIndexer.defaultCacheDirectory)
        let index = idx.build(modFolders: modFolders(), gameFolder: game)
        var names: [String: String] = [:]
        for p in index.modOrder { names[p] = modName(URL(fileURLWithPath: p)) }
        print(String(format: "index built in %.2f s (parsed %d, cached %d)", Date().timeIntervalSince(t0), idx.lastStats.parsed, idx.lastStats.cached))
        return (index, names)
    }
}
