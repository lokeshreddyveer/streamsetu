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

#if canImport(SwiftUI)
import SwiftUI

/// The moods and examples as tappable chips.
struct SearchIdeasPanel: View {
    var pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What are you in the mood for?").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            FlowChips(items: SearchIdeas.moods, pick: pick)
            Text("Or try").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SearchIdeas.examples) { e in
                    Button { pick(e.query) } label: { Label(e.label, systemImage: e.symbol).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
                        .buttonStyle(.plain).padding(.vertical, 3)
                }
            }
        }
        .padding(14)
    }
}

private struct FlowChips: View {
    let items: [SearchIdea]
    var pick: (String) -> Void
    var body: some View {
        let rows = stride(from: 0, to: items.count, by: 2).map { Array(items[$0..<min($0 + 2, items.count)]) }
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 6) {
                    ForEach(rows[r]) { i in
                        Button { pick(i.query) } label: {
                            Label(i.label, systemImage: i.symbol).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                .padding(.horizontal, 10).padding(.vertical, 6).background(Color.accentColor.opacity(0.14), in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
#endif
