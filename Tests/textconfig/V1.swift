// Health.swift v1's text config.cpp CfgPatches reader, copied verbatim (it is private there and
// Health.swift needs AppKit + the app's Mod type), so v1 and v2 can be compared file by file.
import Foundation

enum V1Text {
    /// addon class name → addons it requires (all lowercased).
    static func text(_ data: Data) -> [String: [String]] {
        guard var t = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return [:] }
        t = t.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"//[^\n]*"#, with: "", options: .regularExpression)
        let ns = t as NSString
        let head = ns.range(of: #"class\s+CfgPatches\s*\{"#, options: [.regularExpression, .caseInsensitive])
        guard head.location != NSNotFound else { return [:] }
        let blockStart = NSMaxRange(head), blockEnd = matchingBrace(ns, from: blockStart)

        let classRE = try! NSRegularExpression(pattern: #"class\s+(\w+)\s*(?::\s*\w+\s*)?\{"#)
        let reqRE = try! NSRegularExpression(pattern: #"requiredAddons\[\]\s*=\s*\{([^}]*)\}"#, options: .caseInsensitive)
        var result: [String: [String]] = [:]
        var cursor = blockStart
        while cursor < blockEnd,
              let m = classRE.firstMatch(in: t, range: NSRange(location: cursor, length: blockEnd - cursor)) {
            let bodyStart = NSMaxRange(m.range), bodyEnd = matchingBrace(ns, from: bodyStart)
            let rawName = ns.substring(with: m.range(at: 1))
            let name = rawName.lowercased()
            let body = ns.substring(with: NSRange(location: bodyStart, length: max(0, bodyEnd - bodyStart)))
            cursor = bodyEnd + 1
            if rawName == "ADDON" || t.contains("#define \(rawName)") { continue }
            var required: [String] = []
            if body.range(of: #"skipWhenMissingDependencies\s*=\s*1"#, options: [.regularExpression, .caseInsensitive]) == nil,
               let r = reqRE.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
               let range = Range(r.range(at: 1), in: body) {
                let list = String(body[range])
                if !list.contains("#") {
                    required = list.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"")).lowercased() }
                        .filter { !$0.isEmpty }
                }
            }
            result[name] = required
        }
        return result
    }

    private static func matchingBrace(_ ns: NSString, from: Int) -> Int {
        var depth = 1, i = from
        while i < ns.length {
            switch ns.character(at: i) {
            case 0x7B: depth += 1
            case 0x7D: depth -= 1; if depth == 0 { return i }
            default: break
            }
            i += 1
        }
        return ns.length
    }
}

/// Minimal PBO writer for tests: uncompressed entries plus an optional `prefix` header.
enum PBOWriter {
    static func write(_ url: URL, prefix: String?, files: [(String, String)]) throws {
        var d = Data()
        func cstr(_ s: String) { d.append(contentsOf: Array(s.utf8)); d.append(0) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        cstr(""); u32(PBOArchive.versMagic); u32(0); u32(0); u32(0); u32(0)
        if let prefix { cstr("prefix"); cstr(prefix) }
        cstr("")
        for (name, body) in files { cstr(name); u32(0); u32(UInt32(body.utf8.count)); u32(0); u32(0); u32(UInt32(body.utf8.count)) }
        cstr(""); u32(0); u32(0); u32(0); u32(0); u32(0)
        for (_, body) in files { d.append(contentsOf: Array(body.utf8)) }
        try d.write(to: url)
    }
}
