import Foundation
import CoreGraphics
import Observation

// Pure rules of the right-hand panel: its width, how big the Now Playing cover is for each layout mode, and the keys that open each tab.
// Plain values, so the numbers are tested without a window.

/// How much room the cover takes in the Now Playing tab. Compact keeps the lyrics and controls in view, Balanced is the everyday look, Immersive lets the cover fill the width.
enum MusicNowPlayingMode: String, CaseIterable, Sendable, Identifiable {
    case compact, balanced, immersive
    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: "Compact"
        case .balanced: "Balanced"
        case .immersive: "Immersive"
        }
    }

    var symbol: String {
        switch self {
        case .compact: "rectangle.compress.vertical"
        case .balanced: "rectangle"
        case .immersive: "rectangle.expand.vertical"
        }
    }

    /// The saved mode; anything unknown reads as Balanced.
    static func decode(_ raw: String?) -> MusicNowPlayingMode { raw.flatMap(MusicNowPlayingMode.init(rawValue:)) ?? .balanced }

    /// The share of the panel's height the cover may take (nil means the width alone decides), and the cover's largest edge.
    var heightShare: CGFloat? {
        switch self {
        case .compact: 0.30
        case .balanced: 0.44
        case .immersive: nil
        }
    }

    var largestCover: CGFloat {
        switch self {
        case .compact: 240
        case .balanced: 420
        case .immersive: 500
        }
    }
}

enum MusicNowPlayingSizing {
    static let smallestCover: CGFloat = 120

    /// The cover's edge: never wider than the panel allows (`widthSize`, the existing width rule), never above the mode's largest edge, and, outside Immersive, never taller
    /// than its share of the panel's height, so the lyrics preview has room under the controls. A tiny or unknown height leaves the width rule alone.
    static func coverSize(widthSize: CGFloat, panelHeight: CGFloat, mode: MusicNowPlayingMode) -> CGFloat {
        guard widthSize.isFinite, widthSize > 0 else { return 0 }
        var size = min(widthSize, mode.largestCover)
        if let share = mode.heightShare, panelHeight.isFinite, panelHeight > 0 {
            size = min(size, max(smallestCover, panelHeight * share))
        }
        return max(min(smallestCover, widthSize), size)
    }
}

/// The side panel's width: 280 to 500 points, remembered, and reset by a double click.
enum MusicPanelWidth {
    static let range: ClosedRange<CGFloat> = 280...500
    static let standard: CGFloat = 360
    /// The page keeps at least this much beside the panel and the narrowest sidebar.
    static let pageMinimum: CGFloat = 420

    /// A saved value inside the range, or nil (use the automatic width). Non-finite or out-of-range numbers are ignored, not clamped, so a bad value never sticks.
    static func decode(_ raw: Double?) -> CGFloat? {
        guard let raw, raw.isFinite, range.contains(CGFloat(raw)) else { return nil }
        return CGFloat(raw)
    }

    /// The widest the panel may be in a window `total` points wide: the page and the rail keep their room.
    static func upperLimit(total: CGFloat, railWidth: CGFloat = MusicLayoutGrid.navCompactWidth) -> CGFloat {
        guard total.isFinite else { return range.lowerBound }
        return min(range.upperBound, max(range.lowerBound, total - railWidth - pageMinimum))
    }

    /// The width to draw for a wanted width in a window `total` points wide.
    static func clamped(_ wanted: CGFloat, total: CGFloat) -> CGFloat {
        guard wanted.isFinite else { return standard }
        return min(upperLimit(total: total), max(range.lowerBound, wanted))
    }

    /// The width after a drag: the panel sits on the right, so dragging its left edge to the left makes it wider.
    static func afterDrag(start: CGFloat, translation: CGFloat, total: CGFloat) -> CGFloat {
        clamped(start - translation, total: total)
    }
}

/// The keys that open each tab of the panel (with Command and Option held), and how a key is read back.
enum MusicPanelTabKeys {
    struct Entry: Sendable, Identifiable, Equatable {
        var key: Character
        var tab: MusicContextPanelTab
        var id: Character { key }
    }

    static let all: [Entry] = [
        Entry(key: "1", tab: .nowPlaying), Entry(key: "2", tab: .queue), Entry(key: "3", tab: .lyrics), Entry(key: "4", tab: .related), Entry(key: "5", tab: .credits),
    ]

    static func key(for tab: MusicContextPanelTab) -> Character? { all.first { $0.tab == tab }?.key }
    static func tab(forKey c: Character) -> MusicContextPanelTab? { all.first { $0.key == c }?.tab }
}

/// One labelled fact about the playing recording.
struct MusicRecordingInfoRow: Equatable, Sendable, Identifiable {
    var id: String
    var label: String
    var value: String
}

/// The Credits tab's "Recording" facts: only what the track and its stream really say. Anything unknown is left out, never guessed, and no service is named.
enum MusicRecordingInfo {
    /// The stream facts worth listing here, in this order (the delivery route and the output belong to the quality popover, not to the recording).
    static let technicalIDs = ["codec", "container", "bitrate", "sampleRate", "lossless"]

    static func rows(for t: MusicTrack, technical: [MusicQualityFacts.Row] = []) -> [MusicRecordingInfoRow] {
        var out: [MusicRecordingInfoRow] = []
        if t.durationMs > 0 { out.append(MusicRecordingInfoRow(id: "length", label: Localized.string("Length"), value: MusicTime.clock(ms: t.durationMs))) }
        if let n = t.trackNumber, n > 0 {
            let value = (t.discNumber ?? 0) > 1 ? Localized.string("Disc %1$@, track %2$@", String(t.discNumber ?? 1), String(n)) : String(n)
            out.append(MusicRecordingInfoRow(id: "track", label: Localized.string("Track"), value: value))
        }
        if let r = t.album?.releaseDate?.trimmingCharacters(in: .whitespaces), !r.isEmpty {
            out.append(MusicRecordingInfoRow(id: "released", label: Localized.string("Released"), value: r))
        }
        if t.explicit { out.append(MusicRecordingInfoRow(id: "content", label: Localized.string("Content"), value: Localized.string("Explicit"))) }
        if let isrc = t.isrc?.trimmingCharacters(in: .whitespaces), !isrc.isEmpty { out.append(MusicRecordingInfoRow(id: "isrc", label: "ISRC", value: isrc)) }
        for id in technicalIDs {
            if let r = technical.first(where: { $0.id == id }), !r.value.isEmpty { out.append(MusicRecordingInfoRow(id: "tech." + id, label: r.label, value: r.value)) }
        }
        return out
    }
}

/// The "Playing from ..." line under the Now Playing controls. A context is an album, a playlist, a station or a search; a service's own name is never one, so a source that is
/// only a provider's name shows nothing instead of naming the service.
enum MusicPlayingFrom {
    static func line(source: String?, providerNames: [String]) -> String? {
        guard let s = source?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let isProvider = providerNames.contains { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == folded }
        return isProvider ? nil : s
    }
}

/// The lyrics-loading phrases and the rule that keeps their wording in step with the translation tables.
enum MusicLyricsLoadingPhrases {
    static let all = ["Getting the lyrics", "Lyrics are loading", "Checking the lyric sheet", "Lining up the lyrics", "Lyrics are coming together"]
    /// A stable pick per song (the same song always shows the same phrase). Not `hashValue`, which changes between launches.
    static func phrase(for key: String) -> String {
        var h: UInt64 = 1469598103934665603
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return all[Int(h % UInt64(all.count))]
    }
}

/// What a scrub or a seek click may do when the length is not known yet.
enum MusicSeekGuard {
    /// The target in seconds, or nil when the song has no known length (a click would otherwise restart it at zero).
    static func target(fraction: Double, duration: TimeInterval) -> TimeInterval? {
        guard duration.isFinite, duration > 0, fraction.isFinite else { return nil }
        return min(1, max(0, fraction)) * duration
    }
}


/// A "Find lyrics" pressed where the Lyrics tab is not mounted yet: it is remembered here and the tab opens the source search when it appears.
@MainActor @Observable
final class MusicLyricsFindRequest {
    static let shared = MusicLyricsFindRequest()
    private(set) var token = 0
    @ObservationIgnored private var pending = false

    func raise() { pending = true; token += 1 }

    /// True once for each raised request.
    func take() -> Bool {
        let was = pending
        pending = false
        return was
    }
}
