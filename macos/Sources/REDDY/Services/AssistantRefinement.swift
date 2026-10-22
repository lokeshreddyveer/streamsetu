import Foundation

/// The follow-up chips under a list of titles. Each one changes the list that was just shown, using what the app knows about those titles, so the answer is immediate, needs no model, and cannot be
/// mistaken for a title to search for ("Newer ones" is not a show).
enum AssistantRefinement: String, CaseIterable {
    case unwatched = "Only unwatched"
    case shorter = "Something shorter"
    case newer = "Newer ones"
    case surprise = "Surprise me"

    struct Outcome { var results: [AskResult]; var say: String }

    @MainActor static func apply(_ r: AssistantRefinement, to shown: [AskResult], container c: AppContainer) -> Outcome {
        func year(_ x: AskResult) -> Int { x.item.year ?? 0 }
        func minutes(_ x: AskResult) -> Int? { if case .movie(let m) = x.item { return m.durationSeconds.map { Int($0 / 60) } }; return nil }
        switch r {
        case .unwatched:
            let ids = Set(shown.map(\.id))
            let watched = (try? c.historyRepo.rawStrings("SELECT DISTINCT item_id FROM watch_history", [])) ?? []
            let seen = Set(watched).intersection(ids)
            let kept = shown.filter { !seen.contains($0.id) && !$0.watched }
            return kept.isEmpty ? Outcome(results: [], say: "You have watched all of those.") : Outcome(results: kept, say: kept.count == shown.count ? "None of those has been watched yet." : "Here are the \(kept.count) you have not watched.")
        case .shorter:
            let timed = shown.compactMap { x in minutes(x).map { (x, $0) } }
            guard !timed.isEmpty else { return Outcome(results: shown, say: "I don’t have running times for those, so I can’t tell which is shorter.") }
            let sorted = timed.sorted { $0.1 < $1.1 }.map(\.0)
            return Outcome(results: Array(sorted.prefix(max(3, sorted.count / 2))), say: "Shortest first, by the running time in your library.")
        case .newer:
            let dated = shown.filter { year($0) > 0 }.sorted { year($0) > year($1) }
            guard !dated.isEmpty else { return Outcome(results: shown, say: "Those have no release year in your library, so I can’t order them by date.") }
            return Outcome(results: dated, say: "Newest first.")
        case .surprise:
            guard let pick = shown.randomElement() else { return Outcome(results: [], say: "There is nothing to pick from.") }
            return Outcome(results: [pick], say: "How about this one?")
        }
    }
}
