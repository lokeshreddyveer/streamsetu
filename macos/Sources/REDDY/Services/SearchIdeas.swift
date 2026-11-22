import Foundation

/// What to offer when the search box is empty: moods and example searches. Tapping one fills the box; nothing is sent anywhere until the person searches.
struct SearchIdea: Identifiable, Hashable, Sendable {
    let label: String
    let query: String
    let symbol: String
    var id: String { query }
}

enum SearchIdeas {
    static let moods: [SearchIdea] = [
        .init(label: "Date night", query: "something for date night", symbol: "heart"),
        .init(label: "With the kids", query: "a movie with the kids", symbol: "figure.2.and.child.holdinghands"),
        .init(label: "Feel-good", query: "something feel-good and light", symbol: "sun.max"),
        .init(label: "Edge of my seat", query: "something gripping, edge of my seat", symbol: "bolt"),
        .init(label: "Mind-bending", query: "a mind-bending sci-fi thriller", symbol: "sparkles"),
        .init(label: "Make me laugh", query: "something to make me laugh", symbol: "face.smiling"),
        .init(label: "Short one", query: "something short before bed", symbol: "clock"),
        .init(label: "Binge", query: "a series to binge this weekend", symbol: "tv"),
        .init(label: "Hidden gem", query: "a hidden gem I have not watched", symbol: "diamond"),
        .init(label: "Award-winning", query: "award winning movies I have not watched", symbol: "star"),
    ]

    static let examples: [SearchIdea] = [
        .init(label: "top rated telugu movies", query: "top rated telugu movies", symbol: "text.magnifyingglass"),
        .init(label: "hindi movies 2020s, unwatched", query: "hindi movies 2020s unwatched", symbol: "text.magnifyingglass"),
        .init(label: "newest series", query: "newest series", symbol: "text.magnifyingglass"),
        .init(label: "an actor's films: “Prabhas movies”", query: "Prabhas movies", symbol: "person"),
        .init(label: "go to live tv", query: "go to live tv", symbol: "arrow.right"),
        .init(label: "resume", query: "resume", symbol: "play"),
    ]
}
