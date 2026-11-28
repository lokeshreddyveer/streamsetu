import Foundation

// What a player answer means, as a typed result, so the resolver can react to each case differently: skip the client for this song (bot check,
// token needed), remember that nobody can play it (unavailable, age, region, premium), or ask the user to sign in.

enum YouTubePlayability: Sendable, Equatable {
    case playable
    /// "Sign in to confirm you're not a bot": this client or address is flagged right now; other clients may still work.
    case botCheck
    /// The client needs a proof-of-origin token it did not get ("page needs to be reloaded").
    case tokenRequired
    /// The song cannot be played by any client, for the stated reason.
    case unavailable(MusicUnplayableMemory.Verdict)
    case ageRestricted
    /// A plain "please sign in" that is not a bot check: signed-in clients could play it.
    case signInRequired
    /// Anything else YouTube said.
    case other(String)

    /// Reads `playabilityStatus` text. `reason` is the status reason plus the error screen text, any case.
    static func from(status: String, reason: String?) -> YouTubePlayability {
        let r = (reason ?? "").lowercased()
        if status == "OK" { return .playable }
        if r.contains("not a bot") || r.contains("confirm you’re not") || r.contains("confirm you're not") { return .botCheck }
        if r.contains("page needs to be reloaded") || r.contains("needs to be reloaded") { return .tokenRequired }
        if let v = MusicUnplayableMemory.classify(status: status, reason: reason) { return v == .ageRestricted ? .ageRestricted : .unavailable(v) }
        if status == "LOGIN_REQUIRED" { return .signInRequired }
        if status == "ERROR", r.contains("unavailable") { return .unavailable(.removed) }
        return .other(status)
    }

    /// The permanent verdict, when the cause is one no client can change.
    var verdict: MusicUnplayableMemory.Verdict? {
        switch self {
        case .unavailable(let v): return v
        case .ageRestricted: return .ageRestricted
        default: return nil
        }
    }

    /// True when another client or a token could still change the answer.
    var isRetryable: Bool {
        switch self {
        case .botCheck, .tokenRequired, .signInRequired, .other: return true
        default: return false
        }
    }
}

/// The guest client order. Clients whose addresses serve whole files come first; the two old app identities stay last and are accepted only
/// when the middle-of-file probe passes (their addresses stop working after the first MiB).
enum YTMClientOrder {
    static let guest: [YTMClientKey] = [.visionOS, .iosProducer, .tvhtml5Simply, .ios, .androidVR]
    /// Offsets a whole-file probe reads: start, the first MiB boundary, the middle and the tail.
    static func probeRanges(length: Int) -> [ClosedRange<Int>] {
        guard length > 0 else { return [] }
        var out: [ClosedRange<Int>] = [0...min(255, length - 1)]
        if length > 1_048_576 + 4096 { out.append(1_048_576...(1_048_576 + 4095)) }
        let mid = length / 2
        out.append(mid...min(length - 1, mid + 4095))
        out.append(max(0, length - 256)...(length - 1))
        return out
    }
}
