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
}

/// Capability-based detection: the URL's scheme, extension and path hints decide the container, not blind trust in a filename.
enum StreamCapabilities {
    static func container(for url: URL, isLive: Bool = false) -> StreamContainer {
        let scheme = url.scheme?.lowercased() ?? ""
        if ["rtsp", "rtsps", "rtmp", "rtmps", "rtmpt", "udp", "rtp", "srt", "mms", "mmsh"].contains(scheme) { return .rtsp }     // only MPV opens these
        let path = url.path.lowercased()
        let ext = (path as NSString).pathExtension
        switch ext {
        case "m3u8", "m3u": return .hls
        case "mp4", "m4v", "mov": return .mp4
        case "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "vob", "ogv", "3gp": return .mkv     // Apple's player cannot open these; MPV can
        case "mpd": return .dash
        case "ts", "mts", "m2ts": return .mpegTS
        default: break
        }
        if path.contains("/live/") || isLive { return .mpegTS }       // Xtream-style live endpoints without a useful extension
        return .unknown
    }
}

enum EngineSelector {
    #if os(macOS)
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
