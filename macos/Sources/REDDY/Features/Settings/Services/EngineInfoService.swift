import Foundation

/// What each playback engine is, whether it can run on this Mac, and what it supports. Read from the engines themselves.
struct EngineReport: Identifiable, Equatable, Sendable {
    let kind: PlaybackEngineKind
    var available: Bool
    /// Why an engine can't be used, in plain words. nil when it can.
    var problem: String?
    var version: String?
    var capabilities: [String: Bool]
    var id: PlaybackEngineKind { kind }
    var title: String { kind == .avPlayer ? "Apple AVPlayer" : "MPV" }
}

struct LibraryVersions: Equatable, Sendable {
    var mpv: String?
    var ffmpeg: String?
}

enum EngineInfoService {
    @MainActor
    static func reports(_ playback: PlaybackCoordinator) -> [EngineReport] {
        func caps(_ c: PlaybackCapabilities) -> [String: Bool] {
            ["Seeking": c.seeking, "Playback speed": c.rate, "Quality selection": c.qualitySelection, "Audio tracks": c.audioTracks, "Subtitles": c.subtitleTracks,
             "Audio delay": c.audioDelay, "Subtitle delay": c.subtitleDelay, "Subtitle position": c.subtitlePosition, "Audio normalization": c.audioProcessing,
             "Picture in Picture": c.pictureInPicture, "AirPlay": c.airPlay]
        }
        let av = EngineReport(kind: .avPlayer, available: true, problem: nil, version: nil, capabilities: playback.capabilities(of: .avPlayer).map(caps) ?? [:])
        let mpvLib = MPVLibrary.shared
        var mpv = EngineReport(kind: .mpv, available: mpvLib.isAvailable, problem: nil, version: nil, capabilities: playback.capabilities(of: .mpv).map(caps) ?? [:])
        if !mpvLib.isAvailable {
            mpv.problem = mpvLib.loadError.map { "libmpv could not be loaded: \($0)" } ?? "libmpv was not found. StreamSetu looks inside its own Frameworks folder first, then in common Homebrew locations."
        }
        return [av, mpv]
    }

    /// Versions of the libraries inside libmpv, read by starting a throwaway mpv core that never opens a window or a stream.
    static func libraryVersions() -> LibraryVersions {
        let lib = MPVLibrary.shared
        guard lib.isAvailable, let create = lib.create, let ctx = create() else { return LibraryVersions() }
        defer { lib.terminateDestroy?(ctx) }
        for (k, v) in MPVConfiguration.isolationOptions + [("vo", "null"), ("ao", "null"), ("idle", "yes"), ("terminal", "no")] { _ = lib.setOption?(ctx, k, v) }
        guard lib.initialize?(ctx) == 0 else { return LibraryVersions() }
        func prop(_ n: String) -> String? {
            guard let p = lib.getPropertyString?(ctx, n) else { return nil }
            defer { lib.free?(p) }
            return String(cString: p)
        }
        return LibraryVersions(mpv: prop("mpv-version"), ffmpeg: prop("ffmpeg-version"))
    }
}
