// Mutation fuzzing on real config.bin files: the parser must never trap, hang or go quadratic.
import Foundation

enum Fuzz {
    static func samples(limit: Int) -> [Data] {
        let jobs = Corpus.jobs()
        var out: [Data] = []
        var seen = Set<Int>()
        for (k, job) in jobs.enumerated() where k % max(1, jobs.count / (limit * 2)) == 0 {
            guard let a = try? PBOArchive(url: job.pbo) else { continue }
            for e in a.entries where e.path.hasSuffix("config.bin") {
                guard let d = a.contents(of: e), RapParser.isRapified(d), d.count < 400_000, seen.insert(d.hashValue).inserted else { continue }
                out.append(d)
                break
            }
            if out.count >= limit { break }
        }
        return out
    }

    static func run(iterations: Int) {
        let corpus = samples(limit: 150)
        print("fuzz corpus: \(corpus.count) real config.bin files, \(corpus.reduce(0) { $0 + $1.count } / 1024) KB")
        var rng = SplitMix(seed: 0xC0FFEE)
        var parsed = 0, threw = 0, slowest = 0.0, slowestSize = 0
        var reasons: [String: Int] = [:]
        let start = Date()
        for it in 0..<iterations {
            var b = [UInt8](corpus[Int(rng.next() % UInt64(corpus.count))])
            mutate(&b, &rng)
            let d = Data(b)
            let t0 = DispatchTime.now().uptimeNanoseconds
            do { _ = try RapParser.parse(d); parsed += 1 } catch ParseError.format(let m) {
                threw += 1
                reasons[m.split(separator: " ").prefix(3).joined(separator: " "), default: 0] += 1
            } catch { threw += 1; reasons["\(error)", default: 0] += 1 }
            let dt = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
            // Normalize by size: a 400 KB file legitimately takes longer than a 1 KB one.
            if dt / Double(max(d.count, 1)) > slowest / Double(max(slowestSize, 1)) { slowest = dt; slowestSize = d.count }
            if it % 50_000 == 49_999 { print("  \(it + 1) iterations, \(String(format: "%.0f", Date().timeIntervalSince(start))) s") }
        }
        print("fuzz: \(iterations) mutated inputs, parsed \(parsed), threw \(threw), no traps")
        print("worst time per byte: \(String(format: "%.4f", slowest * 1000)) ms on \(slowestSize) bytes (\(String(format: "%.1f", slowest / Double(max(slowestSize, 1)) * 1e9)) ns/byte)")
        for (r, n) in reasons.sorted(by: { $0.value > $1.value }).prefix(15) { print("  \(n)× \(r)") }
    }

    static func mutate(_ b: inout [UInt8], _ rng: inout SplitMix) {
        let rounds = 1 + Int(rng.next() % 4)
        for _ in 0..<rounds {
            guard b.count > 17 else { return }
            let at = 16 + Int(rng.next() % UInt64(b.count - 16))
            switch rng.next() % 9 {
            case 0: b[at] ^= UInt8(1 << (rng.next() % 8))                          // bit flip
            case 1: b[at] = UInt8(truncatingIfNeeded: rng.next())                     // random byte
            case 2, 3:                                                                // random / hostile u32
                let picks: [UInt32] = [0, 1, 15, 16, 0x7FFF_FFFF, 0xFFFF_FFFF, UInt32(b.count), UInt32(at),
                                       UInt32(truncatingIfNeeded: rng.next())]
                let v = picks[Int(rng.next() % UInt64(picks.count))]
                for k in 0..<4 where at + k < b.count { b[at + k] = UInt8(truncatingIfNeeded: v >> (8 * k)) }
            case 4: b.removeSubrange(at..<b.count)                                    // truncate
            case 5: b.removeSubrange(at..<min(b.count, at + 1 + Int(rng.next() % 16)))  // delete a run
            case 6: b.insert(contentsOf: (0..<(1 + Int(rng.next() % 8))).map { _ in UInt8(truncatingIfNeeded: rng.next()) }, at: at)
            case 7: b[at] = [0x80, 0xFF, 0x00, 0x03, 0x05, 0x06][Int(rng.next() % 6)]  // type codes / cint continuation
            default:                                                                  // splice a chunk from elsewhere
                let from = 16 + Int(rng.next() % UInt64(b.count - 16)), n = min(64, b.count - max(at, from))
                if n > 0 { for k in 0..<n { b[at + k] = b[from + k] } }
            }
        }
    }
}
