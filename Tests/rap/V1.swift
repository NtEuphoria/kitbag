// Health.swift v1's rapified CfgPatches reader, copied verbatim apart from using the shared
// ByteReader/ParseError (identical semantics), so its results can be compared file by file.
import Foundation

typealias Patches = [String: [String]]

enum V1 {
    private enum Entry { case cls(String, Int), value(String, Int?), array(String, [String]) }

    private static func body(_ d: Data, at offset: Int) throws -> [Entry] {
        var r = ByteReader(d, at: offset)
        _ = try r.cstr()   // parent class name
        let count = try r.cint()
        var out: [Entry] = []
        for _ in 0..<count {
            switch try r.u8() {
            case 0:
                let name = try r.cstr()
                out.append(.cls(name, Int(try r.u32())))
            case 1:
                let sub = try r.u8()
                let name = try r.cstr()
                switch sub {
                case 0, 4: _ = try r.cstr(); out.append(.value(name, nil))
                case 1: try r.skip(4); out.append(.value(name, nil))
                case 2: out.append(.value(name, Int(Int32(bitPattern: try r.u32()))))
                case 6: try r.skip(8); out.append(.value(name, nil))
                default: throw ParseError.format("v1")
                }
            case 2:
                let name = try r.cstr()
                out.append(.array(name, try array(&r)))
            case 3, 4:
                _ = try r.cstr()
            case 5:
                try r.skip(4)
                let name = try r.cstr()
                out.append(.array(name, try array(&r)))
            default:
                throw ParseError.format("v1")
            }
        }
        return out
    }

    private static func array(_ r: inout ByteReader) throws -> [String] {
        let count = try r.cint()
        var out: [String] = []
        for _ in 0..<count {
            switch try r.u8() {
            case 0, 4: out.append(try r.cstr())
            case 1, 2: try r.skip(4)
            case 6: try r.skip(8)
            case 3: _ = try array(&r)
            default: throw ParseError.format("v1")
            }
        }
        return out
    }

    static func rapified(_ d: Data) throws -> Patches {
        guard d.count > 16, d.prefix(4) == Data([0x00, 0x72, 0x61, 0x50]) else { return [:] }   // "\0raP"
        var result: Patches = [:]
        for case let .cls(name, offset) in try body(d, at: 16) where name.lowercased() == "cfgpatches" {
            for case let .cls(patch, patchOffset) in try body(d, at: offset) {
                var required: [String] = []
                var optional = false
                for entry in try body(d, at: patchOffset) {
                    switch entry {
                    case let .array(n, v) where n.lowercased() == "requiredaddons": required = v
                    case let .value(n, v) where n.lowercased() == "skipwhenmissingdependencies": optional = (v ?? 0) != 0
                    default: break
                    }
                }
                result[patch.lowercased()] = optional ? [] : required.map { $0.lowercased() }
            }
        }
        return result
    }

    /// What Health v1 actually used: `ConfigParser.patches(data, binary: true)` swallows errors.
    static func patches(_ d: Data) -> Patches { (try? rapified(d)) ?? [:] }
}
