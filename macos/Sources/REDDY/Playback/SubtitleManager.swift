import Foundation

enum SubtitleColor: String, CaseIterable, Sendable, Identifiable {
    case white = "White", yellow = "Yellow", green = "Green", cyan = "Cyan"
    var id: String { rawValue }
    /// Components 0…1 (red, green, blue).
    var rgb: (Double, Double, Double) {
        switch self { case .white: (1, 1, 1); case .yellow: (1, 0.9, 0.2); case .green: (0.4, 1, 0.5); case .cyan: (0.4, 0.9, 1) }
    }
    var hex: String { let c = rgb; return String(format: "#%02X%02X%02X", Int(c.0 * 255), Int(c.1 * 255), Int(c.2 * 255)) }
}

struct SubtitleStyle: Sendable, Equatable {
    var sizePercent: Double = 100         // relative to the player's default
    var backgroundOpacity: Double = 0.5
    var color: SubtitleColor = .white
    /// 0 = bottom of the picture … 1 = near the top. Honoured by engines that expose it (mpv); AVPlayer positions captions itself.
    var verticalPosition: Double = 0
    /// Dark outline and a soft shadow around the text, for readability over bright video (mpv).
    var outline = true
}

enum SubtitleManager {
    static func preferredIndex(in tracks: [SubtitleTrack], languages: [String]) -> Int? {
        for lang in languages.map({ $0.lowercased() }) {
            if let i = tracks.firstIndex(where: { AudioTrackManager.matches($0.language, lang) }) { return i }
        }
        return nil
    }
}
