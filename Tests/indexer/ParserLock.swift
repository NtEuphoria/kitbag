// Guards the cache key: the summaries depend on the parsers' source, so `ConfigIndexer.parserVersion` must be
// bumped whenever one of them changes. `run lock` records the current sources next to the current version;
// the self-test fails when the sources moved without the version.
import Foundation

enum ParserLock {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let lockFile = root.appendingPathComponent("Tests/indexer/parser.lock")
    static let inputs = ["PBOArchive", "ConfigModel", "ConfigPreprocessor", "TextConfigParser", "RapParser"]

    static func fingerprint() -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for name in inputs {
            let data = (try? Data(contentsOf: root.appendingPathComponent("Sources/\(name).swift"))) ?? Data()
            for b in data { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
            h = (h ^ 0xFF) &* 0x100_0000_01b3
        }
        return String(format: "%016llx", h)
    }

    static func write() {
        let text = "parserVersion=\(ConfigIndexer.parserVersion)\nsources=\(fingerprint())\n"
        try! text.write(to: lockFile, atomically: true, encoding: .utf8)
        print("wrote \(lockFile.path): \(text.replacingOccurrences(of: "\n", with: " "))")
    }

    /// nil when the lock matches the sources and version, else what to do.
    static func problem() -> String? {
        guard let text = try? String(contentsOf: lockFile, encoding: .utf8) else { return "no parser.lock; run `run lock`" }
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") { let kv = line.split(separator: "=", maxSplits: 1); if kv.count == 2 { fields[String(kv[0])] = String(kv[1]) } }
        let now = fingerprint()
        if fields["sources"] == now && fields["parserVersion"] == "\(ConfigIndexer.parserVersion)" { return nil }
        if fields["sources"] != now && fields["parserVersion"] == "\(ConfigIndexer.parserVersion)" {
            return "a parser source changed but ConfigIndexer.parserVersion is still \(ConfigIndexer.parserVersion): bump it, then run `run lock`"
        }
        return "parser.lock is out of date (version \(fields["parserVersion"] ?? "?")); run `run lock`"
    }
}
