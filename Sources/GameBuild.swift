// Which Arma 3 build to launch, and what the Apple Silicon one needs to start on this Mac.
import Foundation

enum GameBuild: String, Codable, CaseIterable, Identifiable {
    case automatic, native, rosetta
    var id: Self { self }

    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .native: "Apple Silicon"
        case .rosetta: "Intel (Rosetta)"
        }
    }

    var appName: String { self == .native ? "ArmA3 AS Native" : "ArmA3" }

    func executable(in game: URL) -> URL {
        game.appendingPathComponent("\(appName).app/Contents/MacOS/\(appName)")
    }
}

/// What the Apple Silicon build needs to start here, decided before launch.
enum NativeSupport: Equatable {
    case unavailable(String)   // Intel Mac, or Kitbag itself under Rosetta: why, worded for the player
    case notInstalled
    case supported
    case needsPrivateCache     // see NativeCheck.support

    var canRun: Bool { self == .supported || self == .needsPrivateCache }
}

enum NativeCheck {
    /// The Apple Silicon build is Virtual Programming's Eon wrapper. While starting, Eon reserves memory
    /// for the game at a fixed address (0x300000000 in Eon 1.84) and crashes if it can't get it. macOS 27's
    /// shared system library cache is over 6 GB and always covers that address. Started with
    /// DYLD_SHARED_REGION=private, dyld maps a private copy of the cache instead, which Eon's overwriting
    /// reservation is allowed to replace; the slice it replaces holds only symbol-name strings. The game
    /// then starts and renders, but crashed within five minutes in testing, so only an explicit
    /// Apple Silicon choice uses it.
    static func support(in game: URL) -> NativeSupport {
        if isTranslated {
            return .unavailable("Kitbag is running under Rosetta, so it can't start the Apple Silicon build. Open Kitbag normally to use it.")
        }
        guard isAppleSilicon else { return .unavailable("This Mac has an Intel processor.") }
        let exe = GameBuild.native.executable(in: game)
        guard FileManager.default.isExecutableFile(atPath: exe.path) else { return .notInstalled }
        guard let block = fixedReservation(in: exe), let cache = sharedCacheRange(), block.overlaps(cache) else {
            return .supported
        }
        return .needsPrivateCache
    }

    static var isAppleSilicon: Bool { sysctlFlag("hw.optional.arm64") }
    static var isTranslated: Bool { sysctlFlag("sysctl.proc_translated") }

    private static func sysctlFlag(_ name: String) -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 && value == 1
    }

    /// Finds Eon's fixed reservation in its machine code:
    ///   mov x0, #addr, lsl #32 ; mov w1, #size, lsl #16 ; mov w2, #0x2000 (MEM_RESERVE)
    /// Reading the address from the binary keeps the check right if an update moves or removes it.
    static func fixedReservation(in exe: URL) -> Range<UInt64>? {
        guard let data = try? Data(contentsOf: exe, options: .alwaysMapped) else { return nil }
        return data.withUnsafeBytes { raw -> Range<UInt64>? in
            let words = raw.bindMemory(to: UInt32.self)
            guard words.count > 3 else { return nil }
            for i in 0..<(words.count - 3) {
                let a = UInt32(littleEndian: words[i])
                guard a & 0xFFE0_001F == 0xD2C0_0000 else { continue }   // movz x0, #imm, lsl #32
                let b = UInt32(littleEndian: words[i + 1]), c = UInt32(littleEndian: words[i + 2])
                guard b & 0xFFE0_001F == 0x52A0_0001, c == 0x5284_0002 else { continue }
                let address = UInt64((a >> 5) & 0xFFFF) << 32
                let size = UInt64((b >> 5) & 0xFFFF) << 16
                return address..<(address + size)
            }
            return nil
        }
    }

    /// Every native app in one boot shares the same system cache, so Kitbag's range is the game's too.
    /// The dyld call isn't in the public headers, hence the lookup by name.
    static func sharedCacheRange() -> Range<UInt64>? {
        typealias Fn = @convention(c) (UnsafeMutablePointer<Int>) -> UnsafeRawPointer?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_dyld_get_shared_cache_range") else { return nil }
        var length = 0
        guard let start = unsafeBitCast(sym, to: Fn.self)(&length), length > 0 else { return nil }
        let base = UInt64(UInt(bitPattern: start))
        return base..<(base + UInt64(length))
    }

    /// Changes when Steam updates the Apple Silicon build or macOS updates, so a remembered startup
    /// crash expires with them.
    static func fingerprint(of exe: URL) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: exe.path) else { return nil }
        let size = (a[.size] as? NSNumber)?.int64Value ?? 0
        let modified = Int((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        return "\(size)-\(modified)-\(ProcessInfo.processInfo.operatingSystemVersionString)"
    }
}
