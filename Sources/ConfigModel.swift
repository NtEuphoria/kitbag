// Shared config model: what binary (rapified) and text config parsers produce,
// and the compact per-PBO summary the health checks cache and analyze.
import Foundation

/// A config value as written. Kept only while one PBO is being parsed, then summarized.
indirect enum ConfigValue: Hashable {
    case string(String)
    case number(Double)
    case array([ConfigValue])

    /// Stable short form used to compare two mods' values for the same property.
    var fingerprint: String {
        switch self {
        case .string(let s): return "\"" + s.lowercased() + "\""
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .array(let a): return "{" + a.map(\.fingerprint).joined(separator: ",") + "}"
        }
    }

    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var numberValue: Double? { if case .number(let n) = self { return n }; return nil }
    var arrayValue: [ConfigValue]? { if case .array(let a) = self { return a }; return nil }
}

/// One class in a parsed config tree.
final class ConfigClass {
    let name: String                         // as written
    var parent: String?                      // base class as written, nil when none
    var isExternal: Bool                     // `class X;` forward declaration
    var properties: [String: ConfigValue] = [:]   // lowercased name → value
    var appends: [String: [ConfigValue]] = [:]    // `name[] += {…}` (lowercased name)
    var children: [ConfigClass] = []
    var deletes: [String] = []               // `delete X;` (as written)

    init(name: String, parent: String? = nil, isExternal: Bool = false) {
        self.name = name
        self.parent = parent
        self.isExternal = isExternal
    }

    func child(_ name: String) -> ConfigClass? {
        let n = name.lowercased()
        return children.first { $0.name.lowercased() == n }
    }
}

/// A `CfgPatches` entry: one addon a PBO provides.
struct PatchInfo: Codable, Hashable {
    let name: String                 // lowercased
    var requiredAddons: [String]     // lowercased
    var requiredVersion: Double?
    var skipWhenMissingDependencies: Bool

    static func extract(from root: ConfigClass) -> [PatchInfo] {
        guard let patches = root.child("CfgPatches") else { return [] }
        return patches.children.filter { !$0.isExternal }.map { c in
            let req = (c.properties["requiredaddons"]?.arrayValue ?? [])
                .compactMap { $0.stringValue?.lowercased() }.filter { !$0.isEmpty }
            let skip = (c.properties["skipwhenmissingdependencies"]?.numberValue ?? 0) != 0
            return PatchInfo(name: c.name.lowercased(), requiredAddons: req,
                             requiredVersion: c.properties["requiredversion"]?.numberValue,
                             skipWhenMissingDependencies: skip)
        }
    }
}

/// One class definition, flattened to its full path. `path` is lowercased and `/`-joined
/// from the root, e.g. `cfgvehicles/b_soldier_f`.
struct ClassDef: Codable, Hashable {
    let path: String
    let parent: String?          // lowercased base class name as written (not resolved)
    let external: Bool
    var props: [String: String]  // lowercased property → ConfigValue.fingerprint ("+=" prefix for appends)
    var deletes: [String]        // lowercased names deleted inside this class
}

/// Compact, cacheable result of parsing everything config-related in one PBO.
struct ConfigSummary: Codable {
    var patches: [PatchInfo] = []
    var classes: [ClassDef] = []
    /// Problems found while reading the PBO's config (parse failures, unresolved #include …).
    var diagnostics: [String] = []

    /// Flatten a parsed tree. `includeProperties: false` keeps only paths/parents (used for
    /// the base game, where only "does this class exist / what does it inherit" matters).
    static func make(from root: ConfigClass, includeProperties: Bool) -> ConfigSummary {
        var out = ConfigSummary(patches: PatchInfo.extract(from: root))
        func walk(_ c: ConfigClass, _ path: String) {
            for child in c.children {
                let p = path.isEmpty ? child.name.lowercased() : path + "/" + child.name.lowercased()
                var props: [String: String] = [:]
                if includeProperties {
                    for (k, v) in child.properties { props[k] = v.fingerprint }
                    for (k, v) in child.appends { props[k] = "+=" + ConfigValue.array(v).fingerprint }
                }
                out.classes.append(ClassDef(path: p, parent: child.parent?.lowercased(), external: child.isExternal,
                                            props: props, deletes: child.deletes.map { $0.lowercased() }))
                walk(child, p)
            }
        }
        walk(root, "")
        return out
    }
}
