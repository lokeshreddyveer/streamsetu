import SwiftUI

/// Search results, shown in place of the content area while the top search has text. The header and the sidebar stay where
/// they are and nothing is dimmed; clearing the search returns to the screen that was underneath, unchanged.
struct SearchResultsPage: View {
    let model: GlobalSearchModel
    var focusToken = 0
    let isFavorite: (String) -> Bool
    let onActivate: (SearchResult) -> Void
    @FocusState private var focused: Bool
    @Environment(\.reddyAccent) private var accent
    @Environment(\.container) private var container
    @Environment(AppRouter.self) private var router
    @Environment(AppState.self) private var state

    private static let preview = 6

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    header
                    commandRows
                    if let container { SmartPicksCard(container: container, query: model.term, open: { PlayActions.open($0, router: router) }, force: model.searched && model.visible.isEmpty && model.term.split(separator: " ").count >= 2).padding(.bottom, 8) }
                    tabs.padding(.bottom, 6)
                    content
                }
                .padding(.horizontal, LayoutTokens.gutter).padding(.top, 10).padding(.bottom, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .onChange(of: model.selectedID) { _, id in if let id { proxy.scrollTo(id) } }
        }
        .background(ColorTokens.background)
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
        .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
        .onKeyPress(.return) { if let r = model.selected { onActivate(r); return .handled }; return .ignored }
        .onChange(of: focusToken) { _, _ in focused = true }
        .accessibilityElement(children: .contain).accessibilityLabel("Search results")
    }

    // MARK: pieces

    /// Things the words ask for besides a search ("go to live tv", "play Inception", "add Jersey to watch later"): each is a row, and nothing happens until it is chosen.
    @ViewBuilder private var commandRows: some View {
        let commands = SearchCommands.parse(model.term)
        if !commands.isEmpty, let container {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(commands) { c in
                    Button { SearchCommandRunner.run(c, container: container, router: router, state: state) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: c.symbol).frame(width: 20).foregroundStyle(accent)
                            Text(c.title).font(Typography.rowMedium).lineLimit(1)
                            Spacer()
                            Image(systemName: "return").font(.caption).foregroundStyle(ColorTokens.textTertiary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
                        .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous)).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.padding(.bottom, 8)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(Typography.pageTitle).tracking(-0.6).accessibilityAddTraits(.isHeader)
            Spacer()
            Text("↑↓ choose · ↩ open · Esc clear").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
        }
    }

    private var title: String {
        if model.loading && !model.searched { return "Searching…" }
        let n = model.count(model.tab)
        return "\(n) result\(n == 1 ? "" : "s")"
    }

    private var tabs: some View {
        HStack(spacing: 6) {
            ForEach(SearchTab.allCases) { t in
                Button { model.selectTab(t) } label: {
                    HStack(spacing: 5) {
                        Text(t.rawValue).font(Typography.rowMedium)
                        if model.searched { Text("\(model.count(t))").font(Typography.caption).monospacedDigit().foregroundStyle(ColorTokens.textTertiary) }
                    }
                    .padding(.horizontal, 11).frame(height: 28)
                    .foregroundStyle(model.tab == t ? accent : ColorTokens.textSecondary)
                    .background(model.tab == t ? Color.white.opacity(0.07) : .clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain).accessibilityAddTraits(model.tab == t ? .isSelected : [])
            }
            Spacer()
        }
        .accessibilityElement(children: .contain).accessibilityLabel("Result types")
    }

    /// When a name finds nothing, say that the cast is still being read (and how much), so an actor's films missing is not mistaken for them not being there.
    private var castHint: String {
        guard let container, model.term.split(separator: " ").count >= 2 else { return "" }
        let p = PeopleIndex(db: container.db).progress()
        guard p.total > 0, Double(p.done) / Double(p.total) < 0.9 else { return "" }
        return " If it is an actor, their films may not be read yet: the cast has been read for \(Int(Double(p.done) / Double(p.total) * 100))% of your films. A TMDB key in Settings finds them right away."
    }

    @ViewBuilder private var content: some View {
        if model.loading && !model.searched {
            ProgressView().controlSize(.small).padding(.vertical, 14)
        } else if model.visible.isEmpty {
            EmptyStateView(symbol: "magnifyingglass", title: "No results", message: "Nothing matches “\(model.term)” in any of your playlists\(model.tab == .all ? "" : " under \(model.tab.rawValue)")." + castHint).frame(height: 260)
        } else if model.tab == .all {
            ForEach(SearchResultKind.allCases, id: \.self) { kind in
                let rows = model.results.byKind[kind] ?? []
                if !rows.isEmpty { group(kind, rows) }
            }
        } else {
            VStack(spacing: 0) { ForEach(model.visible) { row($0) } }.padding(.vertical, 4).surface()
            ForEach(Array(model.tab.kinds), id: \.self) { kind in
                if model.results.hasMore.contains(kind) {
                    Button { Task { await model.loadMore(kind) } } label: { Label("Show more \(kind.groupTitle.lowercased())", systemImage: "chevron.down") }
                        .buttonStyle(SecondaryButtonStyle()).padding(.top, 10)
                }
            }
        }
    }

    private func group(_ kind: SearchResultKind, _ rows: [SearchResult]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(kind.groupTitle.uppercased()).font(Typography.eyebrow).tracking(1.2).foregroundStyle(ColorTokens.textSecondary)
                Spacer()
                if let tab = SearchTab.allCases.first(where: { $0 != .all && $0.kinds == [kind] }), rows.count > Self.preview || model.results.hasMore.contains(kind) {
                    Button("Show all") { model.selectTab(tab) }.buttonStyle(.plain).font(Typography.captionMedium).foregroundStyle(accent)
                }
            }.padding(.top, 10)
            VStack(spacing: 0) { ForEach(rows.prefix(Self.preview)) { row($0) } }.padding(.vertical, 4).surface()
        }
    }

    private func row(_ r: SearchResult) -> some View {
        let selected = model.selectedID == r.id
        return Button { model.select(r.id); onActivate(r) } label: {
            HStack(spacing: 12) {
                thumbnail(r)
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.title).font(Typography.rowMedium).lineLimit(1).truncationMode(.tail)
                    if !r.subtitle.isEmpty { Text(r.subtitle).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1).truncationMode(.tail) }
                }
                Spacer(minLength: 8)
                if isFavorite(r.destinationItemID) { Image(systemName: "heart.fill").font(.system(size: 10)).foregroundStyle(accent) }
                Text(r.kind.typeLabel).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(selected ? Color.white.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous)).padding(.horizontal, 6)
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(selected && focused ? accent.opacity(0.7) : .clear).padding(.horizontal, 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).id(r.id)
        .accessibilityLabel("\(r.title), \(r.kind.typeLabel)\(r.sourceName.map { ", from \($0)" } ?? "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private func thumbnail(_ r: SearchResult) -> some View {
        switch r.kind {
        case .channel: ChannelLogo(url: r.artworkURL, name: r.title, size: 30)
        case .movie, .series, .episode:
            ArtworkImage(url: r.artworkURL, kind: r.kind == .episode ? .still : .poster, symbol: r.kind.symbol).frame(width: 30, height: r.kind == .episode ? 20 : 44)
                .clipShape(RoundedRectangle(cornerRadius: 4)).frame(width: 30, height: 44)
        default: Image(systemName: r.kind.symbol).font(.system(size: 13)).foregroundStyle(ColorTokens.textSecondary).frame(width: 30, height: 30)
        }
    }
}

extension SearchResult {
    /// The id the favorites list uses (the catalog item itself), for the heart.
    var destinationItemID: String {
        switch destination {
        case .playChannel(let id): id
        case .movie(let id): id
        case .series(let id): id
        case .episode(let id, _): id
        case .programme, .folder, .collection: ""
        }
    }
}
