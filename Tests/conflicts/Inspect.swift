// Independent look at the real configs: parses the PBOs of a mod directly (bypassing the index) and prints a class.
import Foundation

enum Inspect {
    nonisolated(unsafe) static var vfs: VirtualFileSystem?

    static func allVFS() -> VirtualFileSystem {
        if let v = vfs { return v }
        var urls: [URL] = []
        for m in Lib.modFolders() { urls += loadedPBOs(in: m) }
        urls += ConfigIndexer.vanillaPBOs(in: Lib.game).map(\.url)
        let v = VirtualFileSystem(archives: urls.compactMap { try? PBOArchive(url: $0) })
        vfs = v
        return v
    }

    static func configRoots(pbo url: URL) -> [(file: String, root: ConfigClass)] {
        guard let a = try? PBOArchive(url: url) else { return [] }
        var out: [(String, ConfigClass)] = []
        var cpp: [String: PBOEntry] = [:], bin: [String: PBOEntry] = [:]
        for e in a.entries {
            let p = e.path
            let cut = p.lastIndex(of: "\\")
            let file = cut.map { String(p[p.index(after: $0)...]) } ?? p
            let dir = cut.map { String(p[..<$0]) } ?? ""
            if file == "config.cpp" { cpp[dir] = e } else if file == "config.bin" { bin[dir] = e }
        }
        for dir in Set(cpp.keys).union(bin.keys).sorted() {
            let e = cpp[dir] ?? bin[dir]!
            guard let data = a.contents(of: e) else { continue }
            let vpath = VirtualFileSystem.path(of: e, in: a)
            if RapParser.isRapified(data) {
                if let r = try? RapParser.parse(data) { out.append((vpath, r)) }
            } else {
                let pre = ConfigPreprocessor(vfs: allVFS()).process(VirtualFileSystem.decode(data), path: vpath)
                if let r = try? TextConfigParser.parse(pre.text) { out.append((vpath, r)) }
            }
        }
        return out
    }

    static func navigate(_ root: ConfigClass, _ path: String) -> ConfigClass? {
        var cur = root
        for part in path.split(separator: "/") {
            guard let c = cur.children.last(where: { $0.name.lowercased() == part && !$0.isExternal }) ?? cur.child(String(part)) else { return nil }
            cur = c
        }
        return cur
    }

    static func show(_ c: ConfigClass, depth: Int = 0) {
        let pad = String(repeating: " ", count: 4 + depth * 2)
        print("\(pad)class \(c.name)\(c.parent.map { ": " + $0 } ?? "")\(c.isExternal ? " (external)" : "")")
        for (k, v) in c.properties.sorted(by: { $0.key < $1.key }).prefix(12) { print("\(pad)  \(k) = \(v.fingerprint.prefix(120))") }
        for (k, v) in c.appends.sorted(by: { $0.key < $1.key }).prefix(4) { print("\(pad)  \(k) += \(ConfigValue.array(v).fingerprint.prefix(100))") }
        if !c.deletes.isEmpty { print("\(pad)  deletes: \(c.deletes)") }
        let kids = c.children.map { $0.name + ($0.parent.map { ": " + $0 } ?? "") + ($0.isExternal ? ";" : "") }
        if !kids.isEmpty { print("\(pad)  children: \(kids.prefix(25).joined(separator: ", "))\(kids.count > 25 ? " … \(kids.count)" : "")") }
    }

    /// `dump <modID|path-fragment> <class/path>`; mod "all" scans every mod and the game.
    static func dump(_ args: [String]) {
        guard args.count >= 2 else { print("usage: dump <mod id or 'all' or 'game'> <class/path>"); return }
        let path = args[1].lowercased()
        var targets: [URL] = []
        if args[0] == "game" { targets = ConfigIndexer.vanillaPBOs(in: Lib.game).map(\.url) }
        else if args[0] == "all" { for m in Lib.modFolders() { targets += loadedPBOs(in: m) } }
        else { targets = loadedPBOs(in: Lib.workshop.appendingPathComponent(args[0])) }
        for url in targets {
            for (file, root) in configRoots(pbo: url) {
                if let c = navigate(root, path) {
                    print("\(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent) \(file):")
                    show(c)
                }
            }
        }
    }
}
