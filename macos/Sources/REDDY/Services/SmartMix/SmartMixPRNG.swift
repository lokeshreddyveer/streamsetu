import Foundation

/// Smart Mix PRNG. Integer-only and identical on every platform (the Kotlin twin uses ULong).
/// Contract: smartmix/fixtures/README.md and the vectors in smartmix/fixtures/prng.json.
enum SmartMixPRNG {
    /// FNV-1a 64 over raw bytes.
    static func fnv1a64<S: Sequence>(_ bytes: S) -> UInt64 where S.Element == UInt8 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in bytes { h ^= UInt64(b); h = h &* 0x0000_0100_0000_01b3 }
        return h
    }

    static func seedString(profile: String, shelf: String, day: String, counter: Int) -> String {
        "smartmix1|" + profile + "|" + shelf + "|" + day + "|" + String(counter)
    }

    static func seed(profile: String, shelf: String, day: String, counter: Int) -> UInt64 {
        fnv1a64(seedString(profile: profile, shelf: shelf, day: day, counter: counter).utf8)
    }
}

/// The source of raw 64-bit draws. A protocol only so tests can stub it (to exercise the rejection branch of `uniform`).
protocol SmartMixBitSource {
    mutating func next() -> UInt64
}

struct SplitMix64: SmartMixBitSource {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension SmartMixBitSource {
    /// Unbiased uniform in 0..<n (n >= 1): reject draws below 2^64 mod n.
    mutating func uniform(_ n: UInt64) -> UInt64 {
        precondition(n >= 1)
        let limit = (0 &- n) % n
        while true {
            let x = next()
            if x >= limit { return x % n }
        }
    }
}
