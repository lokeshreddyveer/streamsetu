import SwiftUI

/// The Filter on Movies and Series: a box to find a filter by its name, then folder, language, quality, status, rating and decade. The folder, language and quality names are
/// the ones the open list really has, in alphabetical order.
struct LibraryFilterPanel: View {
    let kind: ContentKind
    @Binding var filter: LibraryFilter
    let options: LibraryFilterOptions
    /// Left empty on the Mac, where the folders are the sidebar.
    var folders: [CatalogCategory] = []
    var selectedFolderID: String?
    var isLocked: (String) -> Bool = { _ in false }
    var pickFolder: (CatalogCategory?) -> Void = { _ in }
    @State private var term = ""

    private var sortedFolders: [CatalogCategory] { folders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
    private func shown(_ label: String) -> Bool { term.trimmingCharacters(in: .whitespaces).isEmpty || label.localizedCaseInsensitiveContains(term.trimmingCharacters(in: .whitespaces)) }

    var body: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search the filters", text: $term).textFieldStyle(.plain).autocorrectionDisabled()
                    if !term.isEmpty { Button { term = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel("Clear the search") }
                }
            }
            if !folders.isEmpty {
                section("Folder", rows: sortedFolders.map { f in (f.name, selectedFolderID == f.id, isLocked(f.id), { pickFolder(f) }) }, any: ("All folders", selectedFolderID == nil, { pickFolder(nil) }))
            }
            section("Language", rows: options.languages.map { l in (l, filter.language == l, false, { filter.language = l }) }, any: ("Any language", filter.language == nil, { filter.language = nil }))
            section("Quality", rows: options.qualities.map { l in (l, filter.quality == l, false, { filter.quality = l }) }, any: ("Any quality", filter.quality == nil, { filter.quality = nil }))
            section("Status", rows: LibraryFilter.statuses(for: kind).map { s in (s.rawValue, filter.status == s, false, { filter.status = s }) }, any: ("Everything", filter.status == nil, { filter.status = nil }))
            section("Rating", rows: LibraryFilterTerms.ratings.map { r in ("\(Int(r))+ stars", filter.minRating == r, false, { filter.minRating = r }) }, any: ("Any rating", filter.minRating == nil, { filter.minRating = nil }))
            section("Release decade", rows: LibraryFilterTerms.decades.map { d in ("\(d)s", filter.decade == d, false, { filter.decade = d }) }, any: ("Any year", filter.decade == nil, { filter.decade = nil }))
            if !term.isEmpty, !anyMatch {
                Text("Nothing is called that. Clear the box to see every filter.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var anyMatch: Bool {
        sortedFolders.contains { shown($0.name) } || options.languages.contains(where: shown) || options.qualities.contains(where: shown)
            || LibraryFilter.statuses(for: kind).contains { shown($0.rawValue) } || LibraryFilterTerms.ratings.contains { shown("\(Int($0))+ stars") } || LibraryFilterTerms.decades.contains { shown("\($0)s") }
    }

    @ViewBuilder private func section(_ title: String, rows: [(label: String, on: Bool, locked: Bool, pick: () -> Void)], any: (label: String, on: Bool, pick: () -> Void)) -> some View {
        let visible = rows.filter { shown($0.label) }
        let showAny = term.isEmpty || shown(any.label) || shown(title)
        if !visible.isEmpty || (showAny && !rows.isEmpty) {
            Section(title) {
                if showAny { row(any.label, on: any.on, locked: false, pick: any.pick) }
                ForEach(visible, id: \.label) { r in row(r.label, on: r.on, locked: r.locked, pick: r.pick) }
            }
        }
    }

    private func row(_ label: String, on: Bool, locked: Bool, pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            HStack {
                Text(label).foregroundStyle(.primary)
                if locked { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if on { Image(systemName: "checkmark").foregroundStyle(ColorTokens.accentDefault) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
