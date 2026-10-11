import Foundation

/// Creates engines on demand and reports which ones can run on this Mac.
@MainActor
final class PlaybackEngineFactory {
    private var av: AVPlayerEngine?
    #if os(macOS) || STREAMSETU_MPV
    private var mpv: MPVPlayerEngine?
    #endif

    var available: Set<PlaybackEngineKind> {
        var s: Set<PlaybackEngineKind> = [.avPlayer]
        #if os(macOS) || STREAMSETU_MPV
        if MPVPlayerEngine.isAvailable { s.insert(.mpv) }
        #endif
        return s
    }

    func engine(_ kind: PlaybackEngineKind) -> any PlaybackEngine {
        switch kind {
        case .avPlayer:
            if av == nil { av = AVPlayerEngine() }
            return av!
        case .mpv:
            #if os(macOS) || STREAMSETU_MPV
            if mpv == nil { mpv = MPVPlayerEngine() }
            return mpv!
            #else
            return avEngine                      // libmpv is not part of the iOS app; AVPlayer plays everything it can
            #endif
        }
    }

    var avEngine: AVPlayerEngine { engine(.avPlayer) as! AVPlayerEngine }
    #if os(macOS) || STREAMSETU_MPV
    var mpvEngine: MPVPlayerEngine? { MPVPlayerEngine.isAvailable ? (engine(.mpv) as? MPVPlayerEngine) : nil }
    #endif
}
