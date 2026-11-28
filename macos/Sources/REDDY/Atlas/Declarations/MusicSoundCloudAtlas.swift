import Foundation

/// Atlas entries for the SoundCloud source: its chapter list for long mixes and its shelf on artist pages.
enum AtlasMusicSoundCloud {
    private static func c(_ id: String, _ title: String, _ summary: String, _ path: [String]) -> AtlasEntry {
        .make(id, .control, title, summary, path: path, platforms: .mac)
    }

    static let all: [AtlasEntry] = [
        c("control.music.soundcloudChapter", "Jump to a chapter of a mix",
          "In Now Playing, a long SoundCloud mix or DJ set lists its tracklist when the description or the uploader's timed comments carry at least three times. Choosing a line jumps to that time. Needs SoundCloud switched on in Music settings.",
          ["Music", "Now Playing", "Chapters"]),
        c("control.music.soundcloudMoreShelf", "More uploads by the artist",
          "A shelf on an artist's page with the artist's own SoundCloud uploads. It appears only when one SoundCloud profile clearly is that artist (the same name and a verified badge or a large following). Needs SoundCloud switched on in Music settings.",
          ["Music", "Artist page"])
    ]
}
