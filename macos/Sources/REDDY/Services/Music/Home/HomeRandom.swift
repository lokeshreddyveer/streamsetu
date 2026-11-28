import Foundation

/// A small seeded generator (SplitMix64). The same seed always gives the same numbers, so a feed composed twice from the same seed is the same feed,
/// and a test can replay any shuffle.
struct HomeSeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Weighted random choice. Weights decide how often something is drawn, not whether: a strong match is drawn most of the time and a weak one now and
/// then (this is what keeps the page from being the same every time without ever being uniform noise).
enum HomeRandom {
    /// `count` distinct items, drawn without replacement, each with a chance proportional to its weight (Efraimidis-Spirakis keys). The order of the
    /// result is the order of the draw (the first is the luckiest). Items with a weight of zero or less are never drawn.
    static func sample<T>(_ items: [T], count: Int, weight: (T) -> Double, using rng: inout some RandomNumberGenerator) -> [T] {
        guard count > 0 else { return [] }
        var keyed: [(key: Double, index: Int)] = []
        keyed.reserveCapacity(items.count)
        for (i, item) in items.enumerated() {
            let w = weight(item)
            guard w > 0, w.isFinite else { continue }
            let u = Double.random(in: Double.leastNormalMagnitude..<1, using: &rng)
            keyed.append((log(u) / w, i))
        }
        keyed.sort { $0.key != $1.key ? $0.key > $1.key : $0.index < $1.index }
        return keyed.prefix(count).map { items[$0.index] }
    }

    static func pick<T>(_ items: [T], weight: (T) -> Double, using rng: inout some RandomNumberGenerator) -> T? {
        sample(items, count: 1, weight: weight, using: &rng).first
    }

    /// A child generator for one part of the page, so adding or removing a shelf does not change the draw of the others.
    static func child(of seed: UInt64, _ name: String) -> HomeSeededGenerator {
        var h: UInt64 = 0xcbf29ce484222325 ^ (seed &* 0x9E3779B97F4A7C15)
        for b in name.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return HomeSeededGenerator(seed: h)
    }
}

/// When a new seed is drawn. A visit within 90 seconds of the last one keeps the same feed, so tiles do not jump under the cursor; the Refresh
/// button always draws a new one.
enum HomeSeedPolicy {
    static let stableSeconds: TimeInterval = 90

    struct Previous: Sendable { var seed: UInt64; var at: Date }

    /// `returning` is true when the person came back with Back or Forward: the page they left is the page they get, however long they were away.
    static func seed(now: Date, previous: Previous?, refresh: Bool, returning: Bool = false, fresh: UInt64 = UInt64.random(in: UInt64.min...UInt64.max)) -> (seed: UInt64, reused: Bool) {
        if !refresh, let p = previous {
            let age = now.timeIntervalSince(p.at)
            if returning || (age >= 0 && age < stableSeconds) { return (p.seed, true) }
        }
        return (fresh, false)
    }
}
