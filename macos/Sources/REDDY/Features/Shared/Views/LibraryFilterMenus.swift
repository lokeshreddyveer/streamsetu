import SwiftUI

/// The extra filters for Movies and Series, as submenus that sit under the sort choices: language, quality, status, rating and release decade.
/// The language and quality names are the ones the open list really has, in alphabetical order.
struct LibraryFilterMenus: View {
    let kind: ContentKind
    @Binding var filter: LibraryFilter
    let options: LibraryFilterOptions

    var body: some View {
        Divider()
        Menu("Language") {
            choice("Any language", on: filter.language == nil) { filter.language = nil }
            ForEach(options.languages, id: \.self) { l in choice(l, on: filter.language == l) { filter.language = l } }
        }
        Menu("Quality") {
            choice("Any quality", on: filter.quality == nil) { filter.quality = nil }
            ForEach(options.qualities, id: \.self) { q in choice(q, on: filter.quality == q) { filter.quality = q } }
        }
        Menu("Status") {
            choice("Everything", on: filter.status == nil) { filter.status = nil }
            ForEach(LibraryFilter.statuses(for: kind)) { s in choice(s.rawValue, on: filter.status == s) { filter.status = s } }
        }
        Menu("Rating") {
            choice("Any rating", on: filter.minRating == nil) { filter.minRating = nil }
            ForEach(LibraryFilterTerms.ratings, id: \.self) { r in choice("\(Int(r))+ stars", on: filter.minRating == r) { filter.minRating = r } }
        }
        Menu("Release decade") {
            choice("Any year", on: filter.decade == nil) { filter.decade = nil }
            ForEach(LibraryFilterTerms.decades, id: \.self) { d in choice("\(d)s", on: filter.decade == d) { filter.decade = d } }
        }
        if filter.isActive { Button("Clear these filters", role: .destructive) { filter = LibraryFilter() } }
    }

    private func choice(_ label: String, on: Bool, _ pick: @escaping () -> Void) -> some View {
        Button(action: pick) { Label(label, systemImage: on ? "checkmark" : "") }
    }
}
