import Foundation

/// What the app knows about one guide source: the last fetch, what it contained, what was skipped, and the error. This is the model behind Settings > Guide > diagnostics.
struct GuideSourceDiagnostics: Sendable, Equatable, Identifiable {
    var id: String { sourceID }
    var sourceID: String
    var name: String = ""
    var kind: GuideSourceKind = .provider
    var host: String?
    var enabled = true
    var lastAttempt: Date?
    var lastSuccess: Date?
    var outcome: String = "never"            // never | ok | notModified | failed | empty
    var httpStatus: Int?
    var bytes: Int64?
    var channelsInFile = 0
    var channelsMapped = 0
    var programmesSeen = 0
    var programmesKept = 0
    var droppedPast = 0
    var droppedFuture = 0
    var droppedInvalid = 0
    var fileFirstStart: Date?
    var fileLastStop: Date?
    var truncated = false
    var error: String?
    /// Programmes and window held right now (read from the guide tables, not from the last fetch).
    var storedProgrammes = 0
    var storedWindowEnd: Date?
    var refreshInterval: TimeInterval = 6 * 3600
}

struct GuideFinding: Sendable, Equatable {
    var key: String
    var level: GuideFreshnessLevel
    var args: [Int] = []
    var text: String
}

enum GuideDiagnosisAdvisor {
    /// Plain-language findings, worst first. This is what explains an empty guide.
    static func findings(_ d: GuideSourceDiagnostics, now: Date, guideDays: Int = 3) -> [GuideFinding] {
        func f(_ key: String, _ level: GuideFreshnessLevel, _ args: [Int] = [], _ s: String? = nil) -> GuideFinding {
            var t = GuideMessages.text[key] ?? key
            if let s { t = t.replacingOccurrences(of: "%@", with: s) }
            for a in args { if let r = t.range(of: "%d") { t.replaceSubrange(r, with: String(a)) } }
            return GuideFinding(key: key, level: level, args: args, text: t)
        }
        var out: [GuideFinding] = []
        if d.lastAttempt == nil { return [f("diag.neverFetched", .warning)] }
        if d.outcome == "failed" { out.append(f("diag.fetchFailed", .error, [], d.error ?? "unknown error")) }
        if d.outcome == "notModified" { out.append(f("diag.notModified", .info)) }
        if d.outcome == "empty" || (d.outcome == "ok" && d.programmesKept == 0) {
            if d.programmesSeen == 0 { out.append(f(d.channelsInFile > 0 ? "diag.emptyFile" : "diag.noChannels", .error)) }
            else if d.droppedInvalid >= d.programmesSeen { out.append(f("diag.invalidTimes", .error)) }
            else if d.droppedPast > 0, d.droppedFuture == 0 {
                let days = d.fileLastStop.map { max(0, Int((now.timeIntervalSince($0) / 86400).rounded())) } ?? 0
                out.append(f("diag.allPast", .error, [days]))
            }
            else if d.droppedFuture > 0, d.droppedPast == 0 { out.append(f("diag.allFuture", .error)) }
            else { out.append(f("diag.partlyOutside", .error, [d.droppedPast + d.droppedFuture, d.programmesSeen])) }
        } else if d.programmesKept > 0 {
            let outside = d.droppedPast + d.droppedFuture
            if d.programmesSeen > 0, outside * 10 > d.programmesSeen * 9 { out.append(f("diag.partlyOutside", .info, [outside, d.programmesSeen])) }
            if d.channelsMapped == 0 { out.append(f("diag.noMapping", .warning)) }
            else if d.channelsInFile > 0, d.channelsMapped * 20 < d.channelsInFile { out.append(f("diag.fewMapped", .info, [d.channelsMapped, d.channelsInFile])) }
        }
        if d.truncated { out.append(f("diag.truncated", .info)) }
        let fr = freshness(d, now: now)
        if fr.level != .fresh, !out.contains(where: { $0.level == .error }) {
            var t = GuideMessages.text[fr.key] ?? fr.key
            if let a = fr.amount, let r = t.range(of: "%d") { t.replaceSubrange(r, with: String(a)) }
            out.append(GuideFinding(key: fr.key, level: fr.level, args: fr.amount.map { [$0] } ?? [], text: t))
        }
        if out.isEmpty { out.append(f("diag.ok", .fresh)) }
        return out.sorted { $0.level > $1.level }
    }

    static func freshness(_ d: GuideSourceDiagnostics, now: Date) -> GuideFreshness {
        GuideFreshness.evaluate(GuideFreshnessInput(now: now, enabled: d.enabled, windowEnd: d.storedWindowEnd, lastSuccess: d.lastSuccess,
                                                    lastAttemptFailed: d.outcome == "failed" || d.outcome == "empty", refreshInterval: d.refreshInterval, programmes: d.storedProgrammes))
    }
}
