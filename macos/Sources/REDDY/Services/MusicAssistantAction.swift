import Foundation

/// What Setu can do in Music. A plain value, so the assistant layer (which every platform compiles) names the action without knowing the Music screens; the Mac's Music
/// module registers the handler that carries it out (`MusicAssistantRegistry.handler`). Where there is no handler (no Music on this device) every request says so.
enum MusicAssistantAction: Equatable, Sendable {
    /// One of `controls`: play, pause, next, previous, shuffle_on, shuffle_off, repeat_off, repeat_all, repeat_one, like, unlike, volume_up, volume_down, mute, unmute, show_lyrics, show_queue.
    case control(String)
    /// Plays what the Music source finds for `query`. `kind` is song, artist, album, playlist or any.
    case play(query: String, kind: String, shuffle: Bool)
    /// A radio from what is playing (`query` nil) or from a song or artist found by name.
    case radio(query: String?)
    /// A Music screen: listen_now, explore, search, library, radio, downloads, devices, listen_together, settings.
    case open(String)
    /// The chart country: an ISO code (in, us...) or "worldwide".
    case country(String)

    static let controls = ["play", "pause", "next", "previous", "shuffle_on", "shuffle_off", "repeat_off", "repeat_all", "repeat_one", "like", "unlike", "volume_up", "volume_down", "mute", "unmute", "show_lyrics", "show_queue"]
    static let screens = ["listen_now", "explore", "search", "library", "radio", "downloads", "devices", "listen_together", "settings"]
    static let kinds = ["song", "artist", "album", "playlist", "any"]

    var title: String {
        switch self {
        case .control(let a): "Music: " + a.replacingOccurrences(of: "_", with: " ")
        case .play(let q, let k, let shuffle): (shuffle ? "Shuffle " : "Play ") + (k == "any" || k == "song" ? "" : k + " ") + "“\(q)” in Music"
        case .radio(let q): q.map { "Start a Music radio from “\($0)”" } ?? "Start a Music radio from this song"
        case .open(let s): "Open Music: " + s.replacingOccurrences(of: "_", with: " ")
        case .country(let c): c.lowercased() == "worldwide" || c.isEmpty ? "Show worldwide charts in Music" : "Show the charts of \(c.uppercased()) in Music"
        }
    }

    var symbol: String {
        switch self {
        case .control(let a): a.hasPrefix("shuffle") ? "shuffle" : a.hasPrefix("repeat") ? "repeat" : a == "pause" ? "pause.fill" : a == "next" ? "forward.fill" : a == "previous" ? "backward.fill" : a.contains("like") ? "heart" : a.contains("volume") || a.contains("mute") ? "speaker.wave.2" : "music.note"
        case .play: "play.fill"
        case .radio: "dot.radiowaves.left.and.right"
        case .open: "music.note.house"
        case .country: "globe"
        }
    }
}

/// The Mac's Music module, as the assistant sees it. Every call answers in plain words the model and the person can read.
@MainActor protocol MusicAssistantHandling: AnyObject {
    /// One line for the assistant's picture of the moment (nil when Music has nothing to say).
    func summary() -> String?
    /// What is playing, in a few lines.
    func nowPlaying() -> String
    /// Songs, artists and albums the Music source finds for `query`, as short lines (names only).
    func search(_ query: String) async -> String
    func run(_ action: MusicAssistantAction) async -> AssistantOutcome
}

@MainActor enum MusicAssistantRegistry {
    static var handler: (any MusicAssistantHandling)?
}
