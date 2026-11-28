import Foundation

/// Finding music by how it sounds, from stored profiles. Pure functions: nothing here reads files or the player.
enum SonicSimilarity {
    struct Item: Equatable, Sendable { var key: String; var profile: SonicProfile }

    /// 0 to 1, how alike two sound vectors are (cosine on the vectors).
    static func likeness(_ a: SonicProfile, _ b: SonicProfile) -> Float {
        let c = SonicDSP.cosine(a.vector, b.vector)
        // Energy and level count for more than the cosine alone shows, so a quiet ballad and a loud anthem with similar harmony are not "alike".
        let penalty = Float(abs(a.energy - b.energy)) * 0.5
        return max(0, min(1, c - penalty))
    }

    private struct Scored { var item: Item; var score: Float }

    private static func rank(_ scored: [Scored], limit: Int) -> [Item] {
        var sorted = scored
        sorted.sort { (x: Scored, y: Scored) -> Bool in x.score != y.score ? x.score > y.score : x.item.key < y.item.key }
        var out: [Item] = []
        for s in sorted.prefix(limit) { out.append(s.item) }
        return out
    }

    static func similar(to target: SonicProfile, excluding: String, in all: [Item], limit: Int = 20) -> [Item] {
        var scored: [Scored] = []
        for c in all where c.key != excluding && !c.profile.vector.isEmpty { scored.append(Scored(item: c, score: likeness(target, c.profile))) }
        return rank(scored, limit: limit)
    }

    /// Two keys mix well on the Camelot wheel when they are the same, a neighbour on the same letter, or the same number on the other letter.
    static func harmonicallyCompatible(_ a: SonicProfile, _ b: SonicProfile) -> Bool {
        guard let ca = a.camelot, let cb = b.camelot, a.keyConfidence > 0.1, b.keyConfidence > 0.1,
              let na = Int(ca.dropLast()), let nb = Int(cb.dropLast()) else { return false }
        let la = ca.last!, lb = cb.last!
        if la == lb { let d = abs(na - nb); return d == 0 || d == 1 || d == 11 }
        return na == nb
    }

    /// Whether two tempos agree, allowing half-time and double-time (within 4 percent).
    static func tempoAgrees(_ a: Double, _ b: Double) -> Bool {
        guard a > 0, b > 0 else { return false }
        for ratio in [1.0, 0.5, 2.0] where abs(a * ratio - b) / b <= 0.04 { return true }
        return false
    }

    /// Rhythm likeness: agreeing tempo plus the shape of the beat histogram.
    static func rhythmLikeness(_ a: SonicProfile, _ b: SonicProfile) -> Float {
        guard let ta = a.bpm, let tb = b.bpm, tempoAgrees(ta, tb) else { return 0 }
        return 0.5 + 0.5 * max(0, SonicDSP.cosine(a.rhythm, b.rhythm))
    }

    static func rhythmSimilar(to target: SonicProfile, excluding: String, in all: [Item], limit: Int = 20) -> [Item] {
        var scored: [Scored] = []
        for c in all where c.key != excluding {
            let r = rhythmLikeness(target, c.profile)
            if r > 0 { scored.append(Scored(item: c, score: r)) }
        }
        return rank(scored, limit: limit)
    }

    static func compatible(with target: SonicProfile, excluding: String, in all: [Item], limit: Int = 20) -> [Item] {
        var scored: [Scored] = []
        for c in all where c.key != excluding && harmonicallyCompatible(target, c.profile) { scored.append(Scored(item: c, score: likeness(target, c.profile))) }
        return rank(scored, limit: limit)
    }

    /// A path of `steps` songs from one to another: the sound vector moves in equal steps, each step takes the nearest song not yet used, and a jump in tempo of
    /// more than 20 percent or a clashing key costs extra. The two end songs are not part of the result.
    static func journey(from a: Item, to b: Item, in all: [Item], steps: Int) -> [Item] {
        guard steps > 0, a.profile.vector.count == b.profile.vector.count, !a.profile.vector.isEmpty else { return [] }
        var used: Set<String> = [a.key, b.key]
        var path: [Item] = []
        var previous = a
        for s in 1...steps {
            let t = Float(s) / Float(steps + 1)
            var waypoint = a.profile.vector
            for i in 0..<waypoint.count { waypoint[i] = a.profile.vector[i] + (b.profile.vector[i] - a.profile.vector[i]) * t }
            var bestItem: Item?
            var bestCost = Float.greatestFiniteMagnitude
            for c in all where !used.contains(c.key) && c.profile.vector.count == waypoint.count {
                var cost = 1 - SonicDSP.cosine(waypoint, c.profile.vector)
                if let tp = previous.profile.bpm, let tc = c.profile.bpm, abs(tp - tc) / tp > 0.2 { cost += 0.25 }
                if !harmonicallyCompatible(previous.profile, c.profile) { cost += 0.05 }
                if cost < bestCost || (cost == bestCost && c.key < (bestItem?.key ?? "~")) { bestCost = cost; bestItem = c }
            }
            guard let pick = bestItem else { break }
            used.insert(pick.key); path.append(pick); previous = pick
        }
        return path
    }

    /// A listening session whose intensity moves gradually from `from` to `to` (energy, 0 to 1) over `count` songs, preferring songs that mix with the one before.
    static func energyProgression(from: Double, to: Double, count: Int, in all: [Item]) -> [Item] {
        guard count > 0 else { return [] }
        var used = Set<String>()
        var out: [Item] = []
        for s in 0..<count {
            let want = count == 1 ? to : from + (to - from) * Double(s) / Double(count - 1)
            var best: Item?
            var bestCost = Double.greatestFiniteMagnitude
            for c in all where !used.contains(c.key) {
                var cost = abs(c.profile.energy - want)
                if let prev = out.last, !harmonicallyCompatible(prev.profile, c.profile) { cost += 0.03 }
                if cost < bestCost || (cost == bestCost && c.key < (best?.key ?? "~")) { bestCost = cost; best = c }
            }
            guard let pick = best else { break }
            used.insert(pick.key); out.append(pick)
        }
        return out
    }
}
