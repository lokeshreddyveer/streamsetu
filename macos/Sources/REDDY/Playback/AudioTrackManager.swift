import Foundation

struct AudioTrack: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let language: String?
    var isSelected: Bool
}

struct SubtitleTrack: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let language: String?
    var isSelected: Bool
}

/// Chooses a default track from the user's preferred languages (ISO 639 codes, in priority order).
enum AudioTrackManager {
    static func preferredIndex(in tracks: [AudioTrack], languages: [String]) -> Int? {
        for lang in languages.map({ $0.lowercased() }) {
            if let i = tracks.firstIndex(where: { matches($0.language, lang) }) { return i }
        }
        return nil
    }

    static func matches(_ trackLanguage: String?, _ wanted: String) -> Bool {
        guard let t = trackLanguage?.lowercased(), !t.isEmpty else { return false }
        return t == wanted || t.hasPrefix(wanted) || wanted.hasPrefix(t)
    }
}
