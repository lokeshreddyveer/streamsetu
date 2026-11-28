import Foundation

// Live soak for the playback failure and retry machinery. See Scripts/music-playback-soak.sh for how to run it.
// For N tracks drawn from chart-style searches (Telugu, Hindi, Tamil, English), source searches (JioSaavn, Audius) and library-style fixtures
// (Apple/iTunes metadata matched to audio), it resolves each track with the app's own MusicStreamResolver, proves the address with the app's own
// stream check, then FAILS THAT ADDRESS ONCE on purpose (the same call the player makes) and resolves again. The retry must give a working address:
// a different one, or the same one checked again when nothing else exists. Nothing is played: no audio engine, no speaker.

let env = ProcessInfo.processInfo.environment
let target = Int(env["SOAK_N"] ?? "") ?? 200
let spacing = Double(env["SOAK_SPACING"] ?? "") ?? 1.0
let botPause = Double(env["SOAK_BOT_PAUSE"] ?? "") ?? 30
let outPath = env["SOAK_OUT"]
let lanesWanted = Set((env["SOAK_LANES"] ?? "").split(separator: ",").map(String.init))

func say(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func errText(_ e: Error) -> String {
    if let m = e as? MusicError { return "MusicError.\(m)" }
    let n = e as NSError
    return "\(n.domain)#\(n.code)"
}

struct Row {
    var lane: String, title: String
    var provider = "-", host = "-", client = "-"
    var first = "FAIL", firstSecs = 0.0, firstError = ""
    var retry = "-"          // fresh | same-working | FAIL | skipped
    var retrySecs = 0.0, retryError = ""
}
nonisolated(unsafe) var rows: [Row] = []

// MARK: queries (chart-style and source-style)

struct Lane { var name: String; var metadataID: String; var queries: [String]; var share: Double }
let lanes: [Lane] = [
    Lane(name: "ytm-telugu", metadataID: "ytmusic", queries: ["telugu top songs", "telugu latest hits", "tollywood chartbusters", "telugu love songs", "allu arjun songs", "devi sri prasad hits", "telugu melody songs", "telugu dance songs"], share: 0.15),
    Lane(name: "ytm-hindi", metadataID: "ytmusic", queries: ["hindi top songs", "bollywood latest hits", "arijit singh best songs", "hindi romantic songs", "bollywood party songs", "pritam hits", "hindi sad songs", "shreya ghoshal best"], share: 0.15),
    Lane(name: "ytm-tamil", metadataID: "ytmusic", queries: ["tamil top songs", "anirudh hits", "ar rahman tamil hits", "tamil latest songs", "kollywood chartbusters", "tamil melody songs", "yuvan shankar raja hits", "tamil dance songs"], share: 0.15),
    Lane(name: "ytm-english", metadataID: "ytmusic", queries: ["top pop songs", "classic rock hits", "hip hop hits", "indie favorites", "the weeknd", "taylor swift", "queen greatest hits", "coldplay hits"], share: 0.15),
    Lane(name: "jiosaavn", metadataID: "jiosaavn", queries: ["arijit singh", "telugu hits", "tamil hits", "punjabi hits", "romantic hindi", "old hindi classics"], share: 0.15),
    Lane(name: "audius", metadataID: "audius", queries: ["electronic", "lofi", "hip hop", "ambient", "house", "chill"], share: 0.10),
    Lane(name: "itunes-matched", metadataID: "itunes", queries: ["Bohemian Rhapsody Queen", "Tum Hi Ho Arijit Singh", "Kaavaalaa Anirudh", "Butta Bomma Armaan Malik", "Blinding Lights The Weeknd", "Shape of You Ed Sheeran", "Believer Imagine Dragons", "Kesariya Arijit Singh", "Srivalli Sid Sriram", "Naatu Naatu Rahul Sipligunj"], share: 0.15),
]

@MainActor func registerBuiltIns(_ reg: MusicRegistry) {
    reg.register(AudiusProvider()); reg.register(JioSaavnProvider()); reg.register(ITunesProvider()); reg.register(SpotifyProvider())
    reg.register(YouTubeMusicProvider()); YouTubeMusicBuiltIns.register(into: reg)
    reg.register(PipedProvider()); reg.register(InvidiousProvider())
}

@MainActor func makeEnvironment() -> (MusicRegistry, MusicStreamResolver, MusicPlaybackLog) {
    let reg = MusicRegistry(defaults: UserDefaults(suiteName: "soak.\(UUID().uuidString)")!)
    registerBuiltIns(reg)
    for p in reg.all where p.id != "local" { reg.setEnabled(true, id: p.id, reason: .setup) }
    let resolver = MusicStreamResolver(registry: reg)
    let log = MusicPlaybackLog()
    resolver.log = log
    return (reg, resolver, log)
}

func looksLikeBotCheck(_ s: String) -> Bool {
    let l = s.lowercased()
    return l.contains("bot") || l.contains("sign in to confirm") || l.contains("429") || l.contains("ratelimited") || l.contains("blocked")
}

@main struct Soak {
    @MainActor static func main() async {
        var (reg, resolver, log) = makeEnvironment()
        var botStreak = 0
        func hostInfo(_ s: MusicStream) -> (String, String) {
            (MusicRedaction.hostClass(s.url), MusicRedaction.client(s.url) ?? "-")
        }
        say("soak: target \(target) tracks, spacing \(spacing)s, bot pause \(botPause)s; no audio is played")

        // 1. collect tracks per lane
        var picked: [(lane: String, track: MusicTrack)] = []
        var seen = Set<String>()
        for lane in lanes where lanesWanted.isEmpty || lanesWanted.contains(lane.name) {
            let quota = max(1, Int((Double(target) * lane.share).rounded()))
            guard let meta = reg.metadataProvider(id: lane.metadataID) else { say("lane \(lane.name): provider missing"); continue }
            var got = 0
            for q in lane.queries where got < quota {
                guard let items = try? await meta.searchTracks(q, page: nil).items else { say("lane \(lane.name): search '\(q)' failed"); continue }
                for t in items where got < quota && seen.insert(t.uid).inserted { picked.append((lane.name, t)); got += 1 }
                try? await Task.sleep(nanoseconds: UInt64(spacing * 1_000_000_000))
            }
            say("lane \(lane.name): \(got) of \(quota) tracks")
        }
        say("collected \(picked.count) tracks")

        // 2. resolve, prove, fail once, resolve again
        for (i, entry) in picked.enumerated() {
            let t = entry.track
            var row = Row(lane: entry.lane, title: t.title)
            let t0 = Date()
            do {
                let first = try await resolver.resolve(t, quality: .high)
                row.firstSecs = Date().timeIntervalSince(t0)
                (row.host, row.client) = hostInfo(first)
                row.provider = resolver.servedProviderName(for: t) ?? t.providerID
                let verdict = await MusicStreamVerifier.verify(first, catalogueMs: t.durationMs)
                if verdict.isOK {
                    row.first = "ok"
                    botStreak = 0
                    // The deliberate failure: exactly what the player does when the stream stops working.
                    resolver.reportFailure(t, stream: first, reason: "soak: failed on purpose")
                    let r0 = Date()
                    do {
                        let second = try await resolver.resolve(t, quality: .high)
                        row.retrySecs = Date().timeIntervalSince(r0)
                        let v2 = await MusicStreamVerifier.verify(second, catalogueMs: t.durationMs)
                        if v2.isOK { row.retry = second.url == first.url ? "same-working" : "fresh" }
                        else { row.retry = "FAIL"; row.retryError = "retry address did not verify: \(v2.reason)" }
                    } catch { row.retry = "FAIL"; row.retryError = errText(error); row.retrySecs = Date().timeIntervalSince(r0) }
                } else { row.first = "FAIL"; row.firstError = "did not verify: \(verdict.reason)"; row.retry = "skipped" }
            } catch {
                row.firstSecs = Date().timeIntervalSince(t0)
                row.firstError = errText(error) + " | " + log.entries.prefix(3).map { "\($0.provider): \($0.reason)" }.joined(separator: "; ")
                row.retry = "skipped"
                if looksLikeBotCheck(row.firstError) { botStreak += 1 } else { botStreak = 0 }
            }
            rows.append(row)
            say("[\(i + 1)/\(picked.count)] \(row.lane) \(row.title.prefix(40)): first \(row.first) retry \(row.retry) \(row.firstError.prefix(80)) \(row.retryError.prefix(80))")
            if botStreak >= 2 {
                say("bot check suspected: pausing \(botPause)s and starting with a fresh identity")
                try? await Task.sleep(nanoseconds: UInt64(botPause * 1_000_000_000))
                (reg, resolver, log) = makeEnvironment()
                botStreak = 0
            } else { try? await Task.sleep(nanoseconds: UInt64(spacing * 1_000_000_000)) }
        }
        report()
    }
}

func report() {
    func e(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ") }
    var md = "# Music playback soak\n\nTracks: \(rows.count). Each stream was proven, failed once on purpose, and resolved again.\n\n"
    md += "| Lane | Tracks | First resolve ok | Retry fresh | Retry same address, working | Retry failed | Median first (s) | Median retry (s) |\n|---|---|---|---|---|---|---|---|\n"
    func median(_ v: [Double]) -> String { v.isEmpty ? "-" : String(format: "%.1f", v.sorted()[v.count / 2]) }
    for lane in Array(Set(rows.map(\.lane))).sorted() + ["ALL"] {
        let r = lane == "ALL" ? rows : rows.filter { $0.lane == lane }
        let ok = r.filter { $0.first == "ok" }
        func pct(_ n: Int, _ d: Int) -> String { d == 0 ? "-" : String(format: "%d (%.0f%%)", n, Double(n) * 100 / Double(d)) }
        md += "| \(lane) | \(r.count) | \(pct(ok.count, r.count)) | \(pct(ok.filter { $0.retry == "fresh" }.count, ok.count)) | \(pct(ok.filter { $0.retry == "same-working" }.count, ok.count)) | \(pct(ok.filter { $0.retry == "FAIL" }.count, ok.count)) | \(median(r.map(\.firstSecs))) | \(median(ok.map(\.retrySecs))) |\n"
    }
    let failedFirst = rows.filter { $0.first != "ok" }
    let failedRetry = rows.filter { $0.retry == "FAIL" }
    md += "\n## Hosts and clients of the addresses that were served\n\n"
    var counts: [String: Int] = [:]
    for r in rows where r.first == "ok" { counts[r.host + (r.client == "-" ? "" : " c=" + r.client), default: 0] += 1 }
    for (k, v) in counts.sorted(by: { $0.value > $1.value }) { md += "- \(k): \(v)\n" }
    if !failedRetry.isEmpty {
        md += "\n## Retries that did not give a working address (these are the bug)\n\n| Lane | Track | Error |\n|---|---|---|\n"
        for r in failedRetry { md += "| \(r.lane) | \(e(r.title)) | \(e(r.retryError)) |\n" }
    }
    if !failedFirst.isEmpty {
        md += "\n## First resolves that failed (not retried)\n\n| Lane | Track | Error |\n|---|---|---|\n"
        for r in failedFirst { md += "| \(r.lane) | \(e(r.title)) | \(e(r.firstError)) |\n" }
    }
    print(md)
    if let outPath { try? md.write(toFile: outPath, atomically: true, encoding: .utf8) }
}
