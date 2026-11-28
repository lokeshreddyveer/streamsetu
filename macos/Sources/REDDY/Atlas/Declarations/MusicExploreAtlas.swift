import Foundation

/// Atlas entries for the Explore hero and country choice and the category page.
enum AtlasMusicExplore {
    private static func c(_ id: String, _ title: String, _ summary: String, _ path: [String]) -> AtlasEntry {
        .make(id, .control, title, summary, path: path, platforms: .mac)
    }

    static let all: [AtlasEntry] = [
        c("control.music.exploreHeroPlay", "Play the featured item", "Plays the featured new release or chart entry at the top of Explore.", ["Music", "Explore"]),
        c("control.music.exploreHeroOpen", "Open the featured item", "Opens the featured new release or chart entry at the top of Explore.", ["Music", "Explore"]),
        c("control.music.categoryPlay", "Play a category", "Plays the songs, or the first playlist, of the mood or genre page.", ["Music", "Explore"]),
        c("control.music.categoryShuffle", "Shuffle a category", "Plays the songs, or the first playlist, of the mood or genre page in random order.", ["Music", "Explore"]),
        c("control.music.categoryShowSongs", "Show every song of a category", "Lists all the songs of a section on a mood or genre page, not only the first few.", ["Music", "Explore"]),
        c("control.music.chartPlay", "Play a chart", "Plays a chart's songs in order, using only the versions that are confirmed playable; the rest join as they are checked.", ["Music", "Explore"]),
        c("control.music.chartShuffle", "Shuffle a chart", "Plays a chart's playable songs in random order.", ["Music", "Explore"]),
        c("control.music.chartShowUnavailable", "Show or hide unavailable chart songs", "Shows the chart songs that have no playable version right now, dimmed, or hides them again.", ["Music", "Explore"]),
    ]
}
