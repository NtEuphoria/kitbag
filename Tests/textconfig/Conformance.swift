// Runs Krzmbrzl/ArmaPreprocessorTestCases (inputs + outputs captured from the real Arma preprocessor)
// against ConfigPreprocessor. Pass the checkout's root; only `validInput` cases are compared.
import Foundation

enum Conformance {
    static func run(root: URL) {
        let fm = FileManager.default
        let tests = root.appendingPathComponent("tests/validInput")
        guard let e = fm.enumerator(at: tests, includingPropertiesForKeys: nil) else { print("no tests at \(tests.path)"); return }
        let vfs = VirtualFileSystem(archives: [])
        var exact = 0, tokens = 0, total = 0
        for case let url as URL in e where url.pathExtension == "sqf" {
            let rel = url.resolvingSymlinksInPath().path.replacingOccurrences(of: tests.resolvingSymlinksInPath().path + "/", with: "")
            let name = url.lastPathComponent
                .replacingOccurrences(of: "ErrorTest", with: "ErrorResult")
                .replacingOccurrences(of: #"^Test(\d+)"#, with: "Result$1", options: .regularExpression)
            let want = root.appendingPathComponent("results/validInput")
                .appendingPathComponent((rel as NSString).deletingLastPathComponent).appendingPathComponent(name)
            guard let input = try? String(contentsOf: url, encoding: .utf8),
                  let expected = try? String(contentsOf: want, encoding: .utf8) else { continue }
            total += 1
            let got = ConfigPreprocessor(vfs: vfs).process(input, path: "test\\" + url.lastPathComponent).text
            let trim = { (s: String) in s.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
            if trim(got) == trim(expected) { exact += 1; tokens += 1; continue }
            if SelfTest.flat(got) == SelfTest.flat(expected) { tokens += 1; continue }
            print("MISMATCH \(rel)\n  input:    \(SelfTest.flat(input).prefix(300))\n  expected: \(SelfTest.flat(expected).prefix(300))\n  got:      \(SelfTest.flat(got).prefix(300))")
        }
        print("conformance: \(tokens)/\(total) match ignoring whitespace layout, \(exact)/\(total) exact (trimmed)")
    }
}
