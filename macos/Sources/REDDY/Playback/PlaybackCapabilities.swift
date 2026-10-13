import Foundation

enum PlaybackEngineKind: String, Sendable, CaseIterable, Identifiable {
    case avPlayer = "Apple AVPlayer"
    case mpv = "MPV"
    var id: String { rawValue }
}

enum PlaybackEnginePreference: String, Sendable, CaseIterable, Identifiable {
    case automatic = "Automatic (recommended)"
    case avPlayer = "Apple AVPlayer"
    case mpv = "MPV"
    var id: String { rawValue }
}

enum StreamContainer: String, Sendable {
    case hls, mp4, mpegTS, mkv, rtsp, dash, unknown
}

struct PlaybackCapabilities: Sendable {
    var containers: Set<StreamContainer>
    var seeking = true
    var rate = true
    var audioTracks = true
    var subtitleTracks = true
    var pictureInPicture = false
    var airPlay = false
    var screenshot = false
    var audioDelay = false
    var audioProcessing = false
    var subtitleDelay = false
    var subtitlePosition = false
    var qualitySelection = false
    var externalSubtitles = false
    /// Can pause and rewind a live stream from its own buffer.
    var liveRewind = false
    var pictureAdjustments = false
    var chapters = false
    var abLoop = false
    var frameStep = false
    /// Can play louder than the system volume (up to 130%).
    var volumeBoost = false
}

/// Capability-based detection: the URL's scheme, extension and path hints decide the container, not blind trust in a filename.
enum StreamCapabilities {
    /// The one list of file types, used by the player chooser, the paste importer and the messages, so they cannot disagree.
    static let hlsExtensions: Set<String> = ["m3u8", "m3u"]
    static let mp4Extensions: Set<String> = ["mp4", "m4v", "mov"]
    static let mkvExtensions: Set<String> = ["mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "vob", "ogv", "3gp"]     // Apple's player cannot open these; MPV can
    static let transportStreamExtensions: Set<String> = ["ts", "mts", "m2ts"]
    static let audioExtensions: Set<String> = ["mp3", "aac", "ogg", "opus", "flac", "m4a"]
    static let schemesForMPV: Set<String> = ["rtsp", "rtsps", "rtmp", "rtmps", "rtmpt", "udp", "rtp", "srt", "mms", "mmsh"]

    /// A single media file (not a playlist): the player plays it instead of reading it as a list.
    static func isMediaFile(extension ext: String) -> Bool {
        let e = ext.lowercased()
        return mp4Extensions.contains(e) || mkvExtensions.contains(e) || transportStreamExtensions.contains(e) || audioExtensions.contains(e)
    }

    static func container(for url: URL, isLive: Bool = false) -> StreamContainer {
        let scheme = url.scheme?.lowercased() ?? ""
        if schemesForMPV.contains(scheme) { return .rtsp }     // only MPV opens these
        let path = url.path.lowercased()
        let ext = (path as NSString).pathExtension
        if hlsExtensions.contains(ext) { return .hls }
        if mp4Extensions.contains(ext) { return .mp4 }
        if mkvExtensions.contains(ext) { return .mkv }
        if ext == "mpd" { return .dash }
        if transportStreamExtensions.contains(ext) { return .mpegTS }
        if path.contains("/live/") || isLive { return .mpegTS }       // Xtream-style live endpoints without a useful extension
        return .unknown
    }
}

enum EngineSelector {
    /// Live MPEG-TS goes to MPV wherever MPV is available: it reads the stream directly (one connection, any codec) and starts in about two
    /// seconds, where Apple's player needs a local relay and cannot play HEVC or MP2 audio in live TS. Apple's player is the backup.
    #if os(macOS) || STREAMSETU_MPV
    static let preferMPVForTransportStream = true
    #else
    static let preferMPVForTransportStream = false
    #endif

    /// Picks an engine for a container. `available` lists engines that can actually run on this Mac right now.
    /// `playlistPreference` is a choice made for one playlist; when set it wins over the app-wide preference.
    /// The most specific choice wins: this channel, then its playlist, then the app-wide setting. "Automatic" at any level defers.
    static func select(container: StreamContainer, preference: PlaybackEnginePreference, playlistPreference: PlaybackEnginePreference? = nil,
                       channelPreference: PlaybackEnginePreference? = nil, available: Set<PlaybackEngineKind>) -> PlaybackEngineKind {
        func specific(_ p: PlaybackEnginePreference?) -> PlaybackEnginePreference? { p.flatMap { $0 == .automatic ? nil : $0 } }
        let chosen = specific(channelPreference) ?? specific(playlistPreference) ?? preference
        switch chosen {
        case .avPlayer: return .avPlayer
        case .mpv: return available.contains(.mpv) ? .mpv : .avPlayer
        case .automatic:
            switch container {
            case .hls, .mp4: return .avPlayer
            // Raw MPEG-TS is not something AVPlayer opens natively; MPV reads it directly. Without MPV it goes through the
            // local HLS bridge in AVPlayer.
            // On iPhone and iPad MPV draws every frame in software, which is far too heavy for live TV: Apple's player (hardware
            // decoding, through the bridge) is used there, and MPV only for the formats Apple's player cannot open.
            case .mpegTS: return preferMPVForTransportStream && available.contains(.mpv) ? .mpv : .avPlayer
            case .mkv, .rtsp, .dash: return available.contains(.mpv) ? .mpv : .avPlayer
            case .unknown: return .avPlayer
            }
        }
    }

    /// An alternative engine to offer after the current one reports an unsupported format.
    static func fallback(from current: PlaybackEngineKind, available: Set<PlaybackEngineKind>) -> PlaybackEngineKind? {
        let other: PlaybackEngineKind = current == .avPlayer ? .mpv : .avPlayer
        return available.contains(other) ? other : nil
    }
}
