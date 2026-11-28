import Foundation

/// Atlas entries for the empty Music Search page's Trending block.
enum AtlasMusicSearch {
    private static func c(_ id: String, _ title: String, _ summary: String, _ path: [String]) -> AtlasEntry {
        .make(id, .control, title, summary, path: path, platforms: .mac)
    }

    static let all: [AtlasEntry] = [
        c("control.music.searchTrendingChip", "Trending search", "A chip in the Trending block of the empty Search page, taken from the chart of the country chosen in Explore. A song or a name runs that search; an artist or album the chart identified opens its page. Shows nothing until a chart source is switched on.", ["Music", "Search"]),
    ]
}
