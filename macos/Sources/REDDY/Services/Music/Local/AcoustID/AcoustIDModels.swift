import Foundation

// Recognising a local recording by its sound. Chromaprint turns the first two minutes of a file into a short fingerprint; AcoustID answers with the MusicBrainz
// recordings that fingerprint belongs to. This file holds the plain parts: reading fpcalc's and AcoustID's replies, and deciding which recording, if any, is the one
// the file really is. Only a fingerprint and a duration ever leave the device, never audio. The result is a suggestion: nothing changes in the person's files or
// library until they approve it.

struct AcoustIDRecording: Codable, Hashable, Sendable, Identifiable {
    var id: String            // the MusicBrainz recording id
    var title: String
    var artists: [String]
    var durationMs: Int64?
    var releaseGroups: [String]
    var score: Double         // AcoustID's own 0...1 match score, the best of its results that name this recording

    var artistLine: String { artists.joined(separator: ", ") }
}

enum AcoustIDError: Error, Equatable, Sendable {
    case needsApplicationKey
    case needsUserKey
    case invalidKey
    case invalidFingerprint
    case rateLimited
    case network(String)
    case server(Int, String)
}

enum ChromaprintOutput {
    /// `fpcalc -json`: {"duration": 641.0, "fingerprint": "AQAB..."}. The duration is whole seconds for the lookup.
    static func parse(_ data: Data) -> (duration: Int, fingerprint: String)? {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let fp = j["fingerprint"] as? String, !fp.isEmpty else { return nil }
        let d = (j["duration"] as? Double) ?? (j["duration"] as? Int).map(Double.init) ?? Double((j["duration"] as? String) ?? "")
        guard let d, d.isFinite, d >= 1 else { return nil }
        return (Int(d.rounded()), fp)
    }
}

enum AcoustIDParser {
    /// The error an AcoustID reply carries, if any. Code 4 is an invalid API key and 21 means a user key is required (the documented codes).
    static func error(in j: [String: Any]) -> AcoustIDError? {
        guard (j["status"] as? String) == "error" || j["error"] != nil else { return nil }
        let e = j["error"] as? [String: Any]
        let code = (e?["code"] as? Int) ?? 0
        let message = (e?["message"] as? String) ?? "error"
        switch code {
        case 3: return .invalidFingerprint
        case 4: return .invalidKey
        case 6: return .needsApplicationKey
        case 21: return .needsUserKey
        case 5, 14: return .rateLimited
        default: return .server(code, message)
        }
    }

    /// A lookup reply: its recordings (one entry per recording, whatever number of AcoustIDs name it, keeping the best score) or the error it carries.
    static func lookup(_ data: Data) -> Result<[AcoustIDRecording], AcoustIDError> {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .failure(.network("unreadable reply")) }
        if let e = error(in: j) { return .failure(e) }
        var best: [String: AcoustIDRecording] = [:]
        for r in (j["results"] as? [[String: Any]]) ?? [] {
            let score = (r["score"] as? Double) ?? Double((r["score"] as? Int) ?? 0)
            for rec in (r["recordings"] as? [[String: Any]]) ?? [] {
                guard let id = rec["id"] as? String, let title = rec["title"] as? String, !title.isEmpty else { continue }
                let artists = ((rec["artists"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
                let ms = (rec["duration"] as? Double).map { Int64($0 * 1000) }
                let groups = ((rec["releasegroups"] as? [[String: Any]]) ?? []).compactMap { $0["title"] as? String }
                let candidate = AcoustIDRecording(id: id, title: title, artists: artists, durationMs: ms, releaseGroups: groups, score: score)
                if let have = best[id], have.score >= score { continue }
                best[id] = candidate
            }
        }
        return .success(best.values.sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id })
    }
}

/// What the file turned out to be.
enum AcoustIDVerdict: Equatable, Sendable {
    /// One recording the evidence agrees on.
    case match(AcoustIDRecording, confidence: Double, reasons: [String])
    /// Several recordings fit about equally well; the person chooses or nothing is changed.
    case ambiguous([AcoustIDRecording])
    /// Nothing fits well enough. The file keeps whatever it has.
    case unconfirmed
}

enum AcoustIDMatcher {
    static let minimumScore = 0.8
    static let strongScore = 0.95
    /// A recording whose length differs from the file by more than this is a different recording (Picard's limit is 30 s; a file is rarely 10 s off).
    static let durationToleranceMs: Int64 = 10_000
    /// Two candidates closer than this in combined confidence cannot be told apart.
    static let ambiguityMargin = 0.08

    struct Local: Sendable {
        var title: String
        var artist: String
        var durationMs: Int64
    }

    /// Combined confidence: AcoustID's score, then what the file's own tags and length say. Blank or placeholder tags say nothing for or against.
    static func confidence(_ r: AcoustIDRecording, local: Local) -> (value: Double, reasons: [String], rejected: Bool) {
        var reasons: [String] = [], value = r.score
        if r.score >= strongScore { reasons.append("fingerprint match") } else { reasons.append("close fingerprint match") }
        if let ms = r.durationMs, local.durationMs > 0 {
            if abs(ms - local.durationMs) > durationToleranceMs { return (0, ["length differs"], true) }
            reasons.append("same length"); value += 0.03
        }
        if !MusicMetadataFill.isBlank(local.title) {
            let s = Double(MusicRelatedMatch.titleScore(local.title, r.title))
            if s >= Double(MusicRelatedMatch.accept) { reasons.append("title agrees"); value += 0.07 }
            else if s < 0.5 { value -= 0.15; reasons.append("title differs") }
        }
        if !MusicMetadataFill.isBlank(local.artist), !r.artists.isEmpty {
            let s = r.artists.map { Double(MusicRelatedMatch.nameScore(local.artist, $0)) }.max() ?? 0
            if s >= Double(MusicRelatedMatch.accept) { reasons.append("artist agrees"); value += 0.07 }
            else if s < 0.5 { value -= 0.1; reasons.append("artist differs") }
        }
        return (min(1, max(0, value)), reasons, false)
    }

    private struct Scored {
        var recording: AcoustIDRecording
        var value: Double
        var reasons: [String]
    }

    static func decide(_ recordings: [AcoustIDRecording], local: Local) -> AcoustIDVerdict {
        var scored: [Scored] = []
        for r in recordings where r.score >= minimumScore {
            let c = confidence(r, local: local)
            if c.rejected || c.value < minimumScore { continue }
            scored.append(Scored(recording: r, value: c.value, reasons: c.reasons))
        }
        scored.sort { (a: Scored, b: Scored) -> Bool in
            if a.value != b.value { return a.value > b.value }
            return a.recording.id < b.recording.id
        }
        guard let top = scored.first else { return .unconfirmed }
        if scored.count > 1, top.value - scored[1].value < ambiguityMargin {
            return .ambiguous(scored.prefix(4).map { $0.recording })
        }
        return .match(top.recording, confidence: top.value, reasons: top.reasons)
    }

    /// The details a match can fill in. With `replace` off only blanks are filled, so what the file already says is never overwritten by a guess.
    static func patch(for r: AcoustIDRecording, entry: LocalEntry, replace: Bool) -> LocalEntryPatch {
        var p = LocalEntryPatch()
        if replace || MusicMetadataFill.isBlank(entry.title) { p.title = r.title }
        if let a = r.artists.first, replace || MusicMetadataFill.isBlank(entry.artist) { p.artist = r.artistLine.isEmpty ? a : r.artistLine }
        if let g = r.releaseGroups.first, replace || MusicMetadataFill.isBlank(entry.album) { p.album = g }
        return p
    }
}
