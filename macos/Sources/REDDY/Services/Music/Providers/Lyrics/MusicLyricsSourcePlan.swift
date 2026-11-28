import Foundation

/// What the app has learned about each lyrics source during this session: how long its answers take and how often it fails. Thread safe;
/// the clock is injected so tests need no waiting. Starting values come from live measurements, so the first song already starts the fast
/// sources first.
final class MusicLyricsSourceStats: @unchecked Sendable {
    struct Prior: Sendable { var p50: Double; var p95: Double }

    /// Measured against the 40-song regional benchmark (see MusicLyricsSourcePlan for the ordering rules).
    static let priors: [String: Prior] = [
        MusicLyricsSources.community: Prior(p50: 0.3, p95: 0.8), MusicLyricsSources.lrclib: Prior(p50: 0.4, p95: 1.3),
        MusicLyricsSources.jioSaavn: Prior(p50: 0.7, p95: 1.6), MusicLyricsSources.lrcRed: Prior(p50: 0.25, p95: 0.5),
        MusicLyricsSources.bini: Prior(p50: 0.25, p95: 0.5), MusicLyricsSources.boidu: Prior(p50: 0.2, p95: 0.4),
        MusicLyricsSources.portato: Prior(p50: 0.2, p95: 0.4), MusicLyricsSources.paxSenix: Prior(p50: 0.5, p95: 3),
        MusicLyricsSources.unison: Prior(p50: 0.7, p95: 1.2), MusicLyricsSources.lyricsPlus: Prior(p50: 6.3, p95: 6.5),
        MusicLyricsSources.simpMusic: Prior(p50: 0.5, p95: 1.5), MusicLyricsSources.youtube: Prior(p50: 0.8, p95: 2),
        MusicLyricsSources.ytCaptions: Prior(p50: 1.0, p95: 2.5), MusicLyricsSources.netease: Prior(p50: 0.75, p95: 1.7),
        MusicLyricsSources.qq: Prior(p50: 0.5, p95: 1.3), MusicLyricsSources.kugou: Prior(p50: 1.1, p95: 1.7),
        MusicLyricsSources.megalobiz: Prior(p50: 2.2, p95: 2.8), MusicLyricsSources.musixmatch: Prior(p50: 1.0, p95: 3),
        MusicLyricsSources.genius: Prior(p50: 1.4, p95: 2.5)]

    private struct Row { var samples: [Double] = []; var failStreak = 0; var lastFailure: Double?; var asks = 0; var hits = 0 }
    private let lock = NSLock()
    private var rows: [String: Row] = [:]
    private let clock: @Sendable () -> Double
    static let keep = 30

    init(clock: @escaping @Sendable () -> Double = { Date().timeIntervalSinceReferenceDate }) { self.clock = clock }

    func record(_ id: String, seconds: Double, answered: Bool, hit: Bool) {
        lock.lock(); defer { lock.unlock() }
        var r = rows[id] ?? Row()
        r.asks += 1
        if answered {
            r.samples.append(seconds); if r.samples.count > Self.keep { r.samples.removeFirst() }
            r.failStreak = 0
            if hit { r.hits += 1 }
        } else { r.failStreak += 1; r.lastFailure = clock() }
        rows[id] = r
    }

    private func percentile(_ p: Double, _ id: String) -> Double? {
        lock.lock(); let s = rows[id]?.samples ?? []; lock.unlock()
        guard s.count >= 5 else { return nil }
        let sorted = s.sorted()
        return sorted[min(sorted.count - 1, Int((p * Double(sorted.count - 1)).rounded()))]
    }

    func p50(_ id: String) -> Double { percentile(0.5, id) ?? Self.priors[id]?.p50 ?? 1.0 }
    func p95(_ id: String) -> Double { percentile(0.95, id) ?? Self.priors[id]?.p95 ?? 3.0 }

    /// How long one request to this source may take: about one and a half times its own p95, never under 2.5 s, never over `cap`.
    func timeout(_ id: String, cap: Double) -> Double { min(cap, max(2.5, p95(id) * 1.5 + 0.4)) }

    /// Failed this many times in a row, the last one within `within` seconds.
    func recentFailures(_ id: String, within: Double = 300) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let r = rows[id], let at = r.lastFailure, clock() - at <= within else { return 0 }
        return r.failStreak
    }

    func reset() { lock.lock(); rows = [:]; lock.unlock() }
}

/// What kind of song this is, from the writing system and a few plain words; used to ask the sources that have such songs first.
struct MusicLyricsLocale: Equatable, Sendable {
    var language: MusicLanguage?
    /// A song from the Indian subcontinent (a regional script or a regional language word).
    var indian: Bool

    private static let words: [String: MusicLanguage] = [
        "telugu": .telugu, "tollywood": .telugu, "hindi": .hindi, "bollywood": .hindi, "tamil": .tamil, "kollywood": .tamil, "kannada": .kannada,
        "sandalwood": .kannada, "malayalam": .malayalam, "mollywood": .malayalam, "punjabi": .punjabi, "bengali": .bengali]

    static func detect(title: String, artists: String, album: String?) -> MusicLyricsLocale {
        let text = [title, artists, album ?? ""].joined(separator: " ")
        if let l = MusicLanguageDetector.language(of: text), l != .latin {
            return MusicLyricsLocale(language: l, indian: l.isSouthAsian)
        }
        let lower = text.lowercased()
        for (w, l) in words where lower.range(of: "\\b\(w)\\b", options: .regularExpression) != nil { return MusicLyricsLocale(language: l, indian: true) }
        return MusicLyricsLocale(language: nil, indian: false)
    }
}

/// Which sources a lookup asks, in which wave and with how many wordings. The rules, from the benchmark:
/// open databases (LRCLIB) and JioSaavn answer in well under a second and hold most regional songs; the Chinese catalogues and the lyrics
/// websites are slower and later; Genius is the last resort. A source that failed lately starts in the second wave, one that keeps failing
/// is left out for two minutes.
enum MusicLyricsSourcePlan {
    struct Choice: Equatable, Sendable { var id: String; var wave: Int; var variants: Int; var timeout: Double }

    /// Sources asked by search words: more than one wording is worth a request.
    static let wordingCount: [String: Int] = [
        MusicLyricsSources.lrclib: 3, MusicLyricsSources.jioSaavn: 3, MusicLyricsSources.netease: 2, MusicLyricsSources.kugou: 2,
        MusicLyricsSources.qq: 2, MusicLyricsSources.paxSenix: 2, MusicLyricsSources.genius: 2]

    /// Best first. Indian songs ask JioSaavn and LRCLIB before everything else; other songs lead with the recording-code sources.
    static func priority(_ locale: MusicLyricsLocale) -> [String] {
        let head: [String] = locale.indian
            ? [MusicLyricsSources.community, MusicLyricsSources.lrclib, MusicLyricsSources.jioSaavn, MusicLyricsSources.ytCaptions, MusicLyricsSources.lrcRed,
               MusicLyricsSources.bini, MusicLyricsSources.boidu, MusicLyricsSources.unison, MusicLyricsSources.simpMusic]
            : [MusicLyricsSources.community, MusicLyricsSources.lrcRed, MusicLyricsSources.lrclib, MusicLyricsSources.bini, MusicLyricsSources.boidu,
               MusicLyricsSources.unison, MusicLyricsSources.ytCaptions, MusicLyricsSources.simpMusic, MusicLyricsSources.portato]
        return head + MusicLyricsSources.defaultOrder.filter { !head.contains($0) }
    }

    /// `enabled` is the person's switched-on sources in their order. Unknown (plugin) sources are asked in the second wave.
    static func plan(enabled: [String], locale: MusicLyricsLocale, stats: MusicLyricsSourceStats, cap: Double = 8) -> [Choice] {
        let rank = priority(locale)
        let ordered = enabled.sorted { (rank.firstIndex(of: $0) ?? Int.max, enabled.firstIndex(of: $0) ?? 0) < (rank.firstIndex(of: $1) ?? Int.max, enabled.firstIndex(of: $1) ?? 0) }
        var out: [Choice] = []
        for id in ordered {
            let failures = stats.recentFailures(id)
            if failures >= 3, stats.recentFailures(id, within: 120) >= 3 { continue }
            var wave: Int
            if MusicLyricsSources.lazyProviders.contains(id) { wave = 2 }
            else if rank.firstIndex(of: id) == nil { wave = 1 }
            else if stats.p50(id) > 2.0 { wave = 1 }
            else { wave = 0 }
            // The Chinese catalogues and lyrics websites hold few regional songs: they follow once the open sources had their chance.
            if wave == 0, locale.indian, [MusicLyricsSources.netease, MusicLyricsSources.qq, MusicLyricsSources.kugou, MusicLyricsSources.megalobiz,
                                           MusicLyricsSources.musixmatch].contains(id) { wave = 1 }
            if wave == 0, !locale.indian, id == MusicLyricsSources.jioSaavn { wave = 1 }
            if failures >= 1, wave == 0 { wave = 1 }
            out.append(Choice(id: id, wave: wave, variants: wordingCount[id] ?? 1, timeout: stats.timeout(id, cap: cap)))
        }
        return out
    }
}
