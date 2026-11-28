import SwiftUI

/// The pure part of the country picker: the list filtered by what was typed, and the row the keyboard is on. No country is named here; the list is whatever
/// `MusicDiscoveryRegion.supported` holds. There are no flags: a country is its name.
enum MusicCountryList {
    typealias Country = (code: String, name: String)

    /// The row after moving `step` rows from `index` inside a list of `count` rows (stops at both ends).
    static func moved(_ index: Int, by step: Int, count: Int) -> Int { count <= 0 ? 0 : max(0, min(count - 1, index + step)) }

    struct Group: Identifiable { let title: String; let items: [Country]; var id: String { title } }

    /// The list as the dropdown shows it. With nothing typed: Worldwide, then "Your region" (the system's country), then "Recent" (the last countries chosen), then every
    /// country under its first letter. With a search: one flat "Results" group. A country appears once: the shortcut groups take it out of the letters only when typed text is empty.
    static func groups(all: [Country], query: String, chosen: String, recents: [String], system: String, worldwide: Country) -> [Group] {
        let q = MusicText.normalize(query)
        if !q.isEmpty {
            var out = filtered(all, query: query, chosen: chosen)
            if MusicText.normalize(worldwide.name).hasPrefix(q) { out.insert(worldwide, at: 0) }
            return out.isEmpty ? [] : [Group(title: "", items: out)]
        }
        var groups: [Group] = [Group(title: "", items: [worldwide])]
        let byCode = Dictionary(all.map { ($0.code, $0) }, uniquingKeysWith: { a, _ in a })
        if let mine = byCode[system.lowercased()] { groups.append(Group(title: "Your region", items: [mine])) }
        let recent = recents.compactMap { byCode[$0] }.filter { $0.code != system.lowercased() }.prefix(3)
        if !recent.isEmpty { groups.append(Group(title: "Recent", items: Array(recent))) }
        var letters: [String: [Country]] = [:]
        for c in all { letters[String(MusicText.normalize(c.name).prefix(1)).uppercased(), default: []].append(c) }
        for k in letters.keys.sorted() { groups.append(Group(title: k, items: letters[k] ?? [])) }
        return groups
    }

    /// Every row in display order (what Up and Down walk).
    static func flat(_ groups: [Group]) -> [Country] { groups.flatMap(\.items) }

    /// Countries matching `query` (the start of the name, the start of any word in it, or the code), in the list's own order, the chosen one first
    /// when nothing is typed. An empty query keeps everything.
    static func filtered(_ all: [Country], query: String, chosen: String) -> [Country] {
        let q = MusicText.normalize(query)
        guard !q.isEmpty else {
            guard let i = all.firstIndex(where: { $0.code == chosen }) else { return all }
            var out = all; let c = out.remove(at: i); out.insert(c, at: 0); return out
        }
        return all.filter { c in
            let n = MusicText.normalize(c.name)
            return n.hasPrefix(q) || n.split(separator: " ").contains { $0.hasPrefix(q) } || c.code == q
        }
    }
}

/// The country control: a pill with a globe and the name that opens a searchable list on a solid surface. Worldwide is first, then the person's own region and the last
/// countries chosen, then every country under its letter. The search box has the keyboard when it opens; Up and Down move the highlight, Return chooses, Escape closes.
struct MusicCountryPicker: View {
    let region: String
    let choose: (String) -> Void
    @State private var open = false
    @State private var query = ""
    @State private var highlight = 0
    @State private var recents: [String] = []
    @FocusState private var searching: Bool
    private static let recentsKey = "music.home.recentCountries"

    var body: some View {
        Button { MusicDebugLog.log("explore", "country pill tapped, open was \(open), region \(region.isEmpty ? "worldwide" : region)"); open.toggle() } label: {
            HStack(spacing: MusicSpace.xs) {
                Image(systemName: "globe").font(.system(size: MusicIconSize.small))
                Text(verbatim: MusicDiscoveryRegion.name(region))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: MusicIconSize.tiny, weight: .bold)).foregroundStyle(ColorTokens.textSecondary)
            }
            .musicChipSurface()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Localized.string("Chart country, %@", MusicDiscoveryRegion.name(region)))
        .atlas("control.music.homeChartCountry")
        .popover(isPresented: $open, arrowEdge: .bottom) { list }
        .musicFocusGuard(isPresented: $open)
        .onChange(of: open) { _, now in
            MusicDebugLog.log("explore", "country list open -> \(now)")
            if now { query = ""; highlight = 0; recents = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? [] }
        }
    }

    private var world: MusicCountryList.Country { (MusicDiscoveryRegion.worldwide, MusicDiscoveryRegion.name(MusicDiscoveryRegion.worldwide)) }
    private var groups: [MusicCountryList.Group] {
        MusicCountryList.groups(all: MusicDiscoveryRegion.supported, query: query, chosen: region, recents: recents, system: MusicDiscoveryRegion.systemDefault(), worldwide: world)
    }

    private func pick(_ code: String) {
        if !code.isEmpty { UserDefaults.standard.set(([code] + recents.filter { $0 != code }).prefix(5).map { $0 }, forKey: Self.recentsKey) }
        MusicDebugLog.log("explore", "country chosen \(code.isEmpty ? "worldwide" : code)")
        choose(code); open = false; query = ""
        searching = false
        MusicFocusGuard.releaseToPage()
    }

    private var searchBox: some View {
        HStack(spacing: MusicSpace.xs) {
            Image(systemName: "magnifyingglass").foregroundStyle(ColorTokens.textTertiary).accessibilityHidden(true)
            TextField(Localized.string("Search countries"), text: $query)
                .textFieldStyle(.plain).focused($searching)
                .onSubmit { if let c = MusicCountryList.flat(groups)[safe: highlight] { pick(c.code) } }
                .onKeyPress(.downArrow) { highlight = MusicCountryList.moved(highlight, by: 1, count: MusicCountryList.flat(groups).count); return .handled }
                .onKeyPress(.upArrow) { highlight = MusicCountryList.moved(highlight, by: -1, count: MusicCountryList.flat(groups).count); return .handled }
                .onChange(of: query) { _, _ in highlight = 0 }
                .atlas("control.music.homeMusichomepagebodyButton")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(ColorTokens.textTertiary) }
                    .buttonStyle(.plain).accessibilityLabel(Localized.string("Clear")).atlas("control.music.homeMusichomepagebodyButton")
            }
        }
        .padding(.horizontal, MusicSpace.sm).frame(height: 34)
        .background(ColorTokens.elevated, in: RoundedRectangle(cornerRadius: MusicCorner.control, style: .continuous))
        .padding(MusicSpace.xs)
    }

    private var list: some View {
        let shown = groups
        let flat = MusicCountryList.flat(shown)
        return VStack(spacing: 0) {
            searchBox
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { gi, g in
                            // Every row has its own place in the list: a country that is in "Recent" and under its letter is two rows, and each has its own id (one id for both drew one blank).
                            let start = shown.prefix(gi).reduce(0) { $0 + $1.items.count }
                            Section {
                                ForEach(Array(g.items.enumerated()), id: \.offset) { i, c in row(c, index: start + i) }
                            } header: {
                                if !g.title.isEmpty {
                                    Text(verbatim: Localized.string(g.title)).musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
                                        .padding(.horizontal, MusicSpace.sm).padding(.vertical, MusicSpace.xxs)
                                        .frame(maxWidth: .infinity, alignment: .leading).background(ColorTokens.surface)
                                }
                            }
                        }
                        if shown.isEmpty { Text(Localized.string("No country found")).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary).padding(MusicSpace.md) }
                    }
                    .padding(.horizontal, MusicSpace.xs).padding(.bottom, MusicSpace.xs)
                }
                .onChange(of: highlight) { _, h in proxy.scrollTo(h) }
            }
        }
        .frame(width: 320, height: 400)
        .background(ColorTokens.surface)
        .defaultFocus($searching, true)
        .onAppear { searching = true }
        // Typing works whether or not the search box got the keyboard: a popover does not always hand it over, and moving focus by hand closes it. So the list itself takes the
        // keys: letters go into the search, Delete takes one away, Return chooses, Escape closes.
        .focusable().focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat]) { press in
            guard !searching else { return .ignored }
            let chars = press.characters
            switch press.key {
            case .return: if let c = MusicCountryList.flat(groups)[safe: highlight] { pick(c.code) }; return .handled
            case .escape: open = false; return .handled
            case .delete: if !query.isEmpty { query.removeLast() }; return .handled
            case .downArrow: highlight = MusicCountryList.moved(highlight, by: 1, count: MusicCountryList.flat(groups).count); return .handled
            case .upArrow: highlight = MusicCountryList.moved(highlight, by: -1, count: MusicCountryList.flat(groups).count); return .handled
            default:
                guard press.modifiers.subtracting([.shift]).isEmpty, let f = chars.unicodeScalars.first, !f.properties.isWhitespace || query.isEmpty == false, f.value >= 32, f.value != 127 else { return .ignored }
                query += chars; return .handled
            }
        }
    }

    private func row(_ c: MusicCountryList.Country, index: Int) -> some View {
        let chosen = c.code == region
        return Button { pick(c.code) } label: {
            HStack(spacing: MusicSpace.sm) {
                Text(verbatim: c.name).foregroundStyle(ColorTokens.textPrimary).fontWeight(chosen ? .semibold : .regular)
                Spacer(minLength: 0)
                if chosen { Image(systemName: "checkmark").foregroundStyle(ColorTokens.accent) }
            }
            .padding(.horizontal, MusicSpace.sm).frame(minHeight: 34).contentShape(Rectangle())
            .background(index == highlight ? ColorTokens.elevated : Color.clear, in: RoundedRectangle(cornerRadius: MusicCorner.control, style: .continuous))
        }
        .buttonStyle(.plain).hoverHighlight()
        .id(index)
        .accessibilityLabel(c.name).accessibilityAddTraits(chosen ? .isSelected : [])
        .atlas("control.music.homeMusichomepagebodyButton")
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
