import Foundation
import Compression

/// The offline alias index: a compact, sorted, read-only list of names (titles and alternative titles in many languages and scripts, Latin transliterations included) with the
/// film or series number each one belongs to. File format (shared with the other platforms, see tools/aliases/README.md): UTF-8 lines `key TAB kind TAB id TAB rank`,
/// sorted by key (byte order) and, within a key, by rank (best first); `kind` is `m` (film) or `t` (series); the file may be gzip-compressed.
/// It is consulted by NAME only: the key of the cleaned name, exactly (`exact`), then by the consonant skeleton (`phonetic`), then by a skeleton one edit away. No year, language or popularity of the library is read.
/// Memory: the decompressed text is kept once (one byte array) plus four bytes per line; the phonetic structures are built on first use (12 bytes per Latin line).
enum AliasKey {
    /// The normalised key of a name: compatibility-composed, lower case, "&" as "and", "+" as "plus", no apostrophes, accents removed from Latin letters only (below U+0370),
    /// every character that is not a letter, digit or combining mark a separator, a leading "the/a/an" dropped when more words follow.
    static func make(_ s: String) -> String {
        var t = s.precomposedStringWithCompatibilityMapping.lowercased()
        t = t.replacingOccurrences(of: "&", with: " and ").replacingOccurrences(of: "+", with: " plus ").replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "").replacingOccurrences(of: "\u{0131}", with: "i")
        var kept = String.UnicodeScalarView()
        for u in t.decomposedStringWithCanonicalMapping.unicodeScalars where !(u.properties.generalCategory == .nonspacingMark && u.value < 0x370) { kept.append(u) }
        var tokens: [String] = [], cur = String.UnicodeScalarView()
        for u in String(kept).precomposedStringWithCanonicalMapping.unicodeScalars {
            switch u.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber, .letterNumber, .otherNumber, .nonspacingMark, .spacingMark, .enclosingMark: cur.append(u)
            default: if !cur.isEmpty { tokens.append(String(cur)); cur = String.UnicodeScalarView() }
            }
        }
        if !cur.isEmpty { tokens.append(String(cur)) }
        if tokens.count > 1, ["the", "a", "an"].contains(tokens[0]) { tokens.removeFirst() }
        return tokens.joined(separator: " ")
    }
}

final class AliasIndex: @unchecked Sendable {
    struct Entry: Equatable, Sendable { let isSeries: Bool; let tmdbID: Int; let rank: Int }
    enum Tier: String, Sendable { case exact, phonetic, edit1 }

    private let blob: [UInt8]
    private let starts: [Int32]        // start of every line; a sentinel at the end
    var count: Int { starts.count - 1 }
    /// Bytes held for the text and the line table (the phonetic structures come on top once used).
    var residentBytes: Int { blob.count + starts.count * 4 }

    init?(data: Data) {
        var raw = data
        if raw.count > 18, raw[raw.startIndex] == 0x1f, raw[raw.startIndex + 1] == 0x8b {
            // gzip: header (10 bytes, plus optional parts), raw deflate, 8 byte trailer.
            let b = [UInt8](raw); let flags = b[3]; var p = 10
            if flags & 4 != 0 { p += 2 + Int(b[p]) + (Int(b[p + 1]) << 8) }
            if flags & 8 != 0 { while p < b.count, b[p] != 0 { p += 1 }; p += 1 }
            if flags & 16 != 0 { while p < b.count, b[p] != 0 { p += 1 }; p += 1 }
            if flags & 2 != 0 { p += 2 }
            guard p < b.count - 8, let out = try? (Data(b[p..<(b.count - 8)]) as NSData).decompressed(using: .zlib) else { return nil }
            raw = out as Data
        }
        blob = [UInt8](raw)
        var s: [Int32] = []; s.reserveCapacity(blob.count / 24)
        var i = 0
        while i < blob.count { s.append(Int32(i)); while i < blob.count, blob[i] != 10 { i += 1 }; i += 1 }
        s.append(Int32(blob.count))
        starts = s
    }

    /// The index shipped in the app's resources (`aliases.tsv.gz`), or nil when the build has none.
    static func bundled(_ bundle: Bundle = .main) -> AliasIndex? {
        guard let u = bundle.url(forResource: "aliases", withExtension: "tsv.gz"), let d = try? Data(contentsOf: u, options: .mappedIfSafe) else { return nil }
        return AliasIndex(data: d)
    }

    // MARK: lines

    private func key(_ line: Int) -> ArraySlice<UInt8> {
        let a = Int(starts[line]), end = Int(starts[line + 1])
        var e = a; while e < end, blob[e] != 9 { e += 1 }
        return blob[a..<e]
    }
    func entry(_ line: Int) -> Entry {
        let a = Int(starts[line]), end = Int(starts[line + 1])
        var e = a; while e < end, blob[e] != 9 { e += 1 }
        let isSeries = e + 1 < end && blob[e + 1] == UInt8(ascii: "t")
        var f = [Int](), n = 0, p = e + 3
        while p < end { let c = blob[p]; if c == 9 { f.append(n); n = 0 } else if c >= 48 && c <= 57 { n = n * 10 + Int(c - 48) }; p += 1 }
        f.append(n)
        return Entry(isSeries: isSeries, tmdbID: f.first ?? 0, rank: f.count > 1 ? f[1] : 0)
    }
    func keyString(_ line: Int) -> String { String(decoding: key(line), as: UTF8.self) }

    private func lowerBound(_ k: [UInt8]) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if key(mid).lexicographicallyPrecedes(k) { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    // MARK: tier 1: exact

    /// The best entry of that kind whose key is exactly the key of `name`.
    func exact(_ name: String, isSeries: Bool) -> Entry? {
        let k = Array(AliasKey.make(name).utf8)
        guard !k.isEmpty else { return nil }
        var i = lowerBound(k)
        while i < count, Array(key(i)) == k { let e = entry(i); if e.isSeries == isSeries { return e }; i += 1 }
        return nil
    }

    // MARK: tiers 2 and 3: phonetic

    private let lock = NSLock()
    private var built = false
    private var hashes: [UInt64] = []        // sorted; skeleton hash with the kind folded in
    private var lines: [Int32] = []          // best line of each hash
    private var buckets: [UInt32: [Int32]] = [:]   // (kind, skeleton length, first letter) -> best lines
    static let minSkeleton = 4, minEdit1Skeleton = 6

    private static func hash(_ skel: String, _ series: Bool) -> UInt64 {
        var h: UInt64 = series ? 0xcbf29ce484222325 : 0x84222325cbf29ce4
        for b in skel.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
    private static func bucketKey(_ skel: String, _ series: Bool) -> UInt32 { UInt32(series ? 1 << 24 : 0) | UInt32(min(skel.utf8.count, 255)) << 8 | UInt32(skel.utf8.first ?? 0) }
    static func skeleton(ofKey k: String) -> String { ArtworkMatchDecision.skeleton(k) }

    private func buildPhonetic() {
        lock.lock(); defer { lock.unlock() }
        if built { return }
        var pairs: [(UInt64, Int32, Int)] = []
        for i in 0..<count {
            let k = key(i)
            guard k.allSatisfy({ $0 < 0x80 }), k.count >= 5 else { continue }
            let skel = Self.skeleton(ofKey: String(decoding: k, as: UTF8.self))
            guard skel.utf8.count >= Self.minSkeleton else { continue }
            let e = entry(i)
            pairs.append((Self.hash(skel, e.isSeries), Int32(i), e.rank))
        }
        pairs.sort { $0.0 != $1.0 ? $0.0 < $1.0 : ($0.2 != $1.2 ? $0.2 > $1.2 : $0.1 < $1.1) }
        var hs: [UInt64] = [], ls: [Int32] = [], bk: [UInt32: [Int32]] = [:]
        for p in pairs where hs.last != p.0 {
            hs.append(p.0); ls.append(p.1)
            let e = entry(Int(p.1)); let skel = Self.skeleton(ofKey: keyString(Int(p.1)))
            if skel.utf8.count >= Self.minEdit1Skeleton - 1 { bk[Self.bucketKey(skel, e.isSeries), default: []].append(p.1) }
        }
        hashes = hs; lines = ls; buckets = bk; built = true
    }
    /// Bytes of the phonetic structures once built.
    var phoneticBytes: Int { lock.lock(); defer { lock.unlock() }; return hashes.count * 12 + buckets.values.reduce(0) { $0 + $1.count * 4 + 24 } }

    /// The entry whose consonant skeleton equals the name's (tier 2), else one whose skeleton is one edit away (tier 3, skeletons of 6+ letters). Best rank wins.
    func phonetic(_ name: String, isSeries: Bool) -> (Entry, Tier)? {
        let k = AliasKey.make(name)
        guard k.utf8.allSatisfy({ $0 < 0x80 }) else { return nil }
        let skel = Self.skeleton(ofKey: k)
        guard skel.utf8.count >= Self.minSkeleton else { return nil }
        buildPhonetic()
        let h = Self.hash(skel, isSeries)
        var lo = 0, hi = hashes.count
        while lo < hi { let m = (lo + hi) / 2; if hashes[m] < h { lo = m + 1 } else { hi = m } }
        if lo < hashes.count, hashes[lo] == h { return (entry(Int(lines[lo])), .phonetic) }
        guard skel.utf8.count >= Self.minEdit1Skeleton else { return nil }
        let q = Array(skel.utf8)
        var best: Entry?
        for d in -1...1 {
            let len = q.count + d
            guard len > 0, let first = q.first else { continue }
            let bk = UInt32(isSeries ? 1 << 24 : 0) | UInt32(min(len, 255)) << 8 | UInt32(first)
            for li in buckets[bk] ?? [] {
                let c = Array(Self.skeleton(ofKey: keyString(Int(li))).utf8)
                if Self.withinOneEdit(q, c) { let e = entry(Int(li)); if best == nil || e.rank > best!.rank { best = e } }
            }
        }
        return best.map { ($0, .edit1) }
    }

    static func withinOneEdit(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        if a == b { return true }
        if abs(a.count - b.count) > 1 { return false }
        var i = 0; while i < a.count, i < b.count, a[i] == b[i] { i += 1 }
        if a.count == b.count { return Array(a.dropFirst(i + 1)) == Array(b.dropFirst(i + 1)) }
        return a.count > b.count ? Array(a.dropFirst(i + 1)) == Array(b.dropFirst(i)) : Array(a.dropFirst(i)) == Array(b.dropFirst(i + 1))
    }

    /// Exact, then phonetic, then one edit away; nil when none of them has the name.
    func resolve(_ name: String, isSeries: Bool, phonetic usePhonetic: Bool = true) -> (Entry, Tier)? {
        if let e = exact(name, isSeries: isSeries) { return (e, .exact) }
        return usePhonetic ? phonetic(name, isSeries: isSeries) : nil
    }
}
