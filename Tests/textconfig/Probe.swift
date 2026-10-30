// Debug helper: `run probe <virtual path> [bytes]` lists the entries of the PBO holding a file and shows its head.
import Foundation

enum Probe {
    static func escaped(_ s: String) -> String {
        s.unicodeScalars.map { $0.value > 126 || $0.value < 32 ? String(format: "\\u{%X}", $0.value) : String($0) }.joined()
    }

    static func run(_ path: String, bytes: Int) {
        let (mods, vanilla, _) = Corpus.load()
        let want = VirtualFileSystem.normalize(path)
        for ar in mods.flatMap(\.archives) + vanilla {
            for e in ar.entries where VirtualFileSystem.path(of: e, in: ar) == want {
                print("PBO: \(ar.url.path)\nprefix: \(ar.prefix)\nentries:")
                for x in ar.entries { print("  \(escaped(x.path))  [\(x.size)]") }
                guard let d = ar.contents(of: e) else { continue }
                print("--- text:\n" + String(decoding: d.prefix(bytes), as: UTF8.self))
            }
        }
    }
}
