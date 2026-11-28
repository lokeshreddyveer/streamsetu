import SwiftUI

/// How the songs of a playlist are drawn: the full rows with artwork, the compact rows, or the table with an album column. Remembered for every playlist.
enum MusicPlaylistViewMode: String, CaseIterable, Identifiable, Sendable {
    case comfortable, compact, table
    var id: String { rawValue }
    static let key = "music.playlistViewMode"

    var rowStyle: MusicTrackRowStyle {
        switch self { case .comfortable: .standard; case .compact: .compact; case .table: .table }
    }
    var title: String {
        switch self {
        case .comfortable: Localized.string("With artwork")
        case .compact: Localized.string("Compact")
        case .table: Localized.string("Table")
        }
    }
    var symbol: String {
        switch self { case .comfortable: "list.bullet.below.rectangle"; case .compact: "list.bullet"; case .table: "tablecells" }
    }

    static func load(_ defaults: UserDefaults = .standard) -> MusicPlaylistViewMode {
        defaults.string(forKey: key).flatMap(MusicPlaylistViewMode.init(rawValue:)) ?? .comfortable
    }
    func save(_ defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: Self.key) }
}

/// The icon buttons that follow Play and Shuffle: add to queue, play next, download, share, and the choice of how the songs are drawn. The page decides
/// what each one does (a service's list loads its remaining pages first), so one row serves the person's own playlists and a service's.
struct MusicPlaylistIconRow: View {
    let enabled: Bool
    let onQueue: () -> Void
    let onNext: () -> Void
    var onDownload: (() -> Void)?
    let onShare: () -> Void
    @Binding var mode: MusicPlaylistViewMode

    var body: some View {
        MusicPlaylistIconButton(symbol: "text.append", label: "Add to Queue", atlasID: "control.music.playlistAddToQueue", disabled: !enabled, action: onQueue)
        MusicPlaylistIconButton(symbol: "text.insert", label: "Play Next", atlasID: "control.music.playlistPlayNext", disabled: !enabled, action: onNext)
        if let onDownload {
            MusicPlaylistIconButton(symbol: "arrow.down.circle", label: "Download", atlasID: "control.music.playlistDownload", disabled: !enabled, action: onDownload)
        }
        MusicPlaylistIconButton(symbol: "square.and.arrow.up", label: "Share…", atlasID: "control.music.playlistShare", action: onShare)
        Menu {
            Picker("View as", selection: Binding(get: { mode }, set: { mode = $0; $0.save() })) {
                ForEach(MusicPlaylistViewMode.allCases) { m in Label(m.title, systemImage: m.symbol).tag(m) }
            }.atlas("control.music.playlistViewAs")
            .pickerStyle(.inline)
        } label: { Image(systemName: mode.symbol).font(MusicTokens.iconLarge) }
            .menuStyle(.button).menuIndicator(.hidden).musicButton(.glassIcon, size: .large).fixedSize()
            .accessibilityLabel("View as").help("View as").atlas("control.music.playlistViewAs")
    }
}

/// Loads every remaining page of a service's playlist, so Play, Shuffle, Save and Download cover the whole list and not just the pages shown
/// (a shuffle of 10,000 songs that only mixed the first 100 is a known complaint). Stops at a failed page.
@MainActor
enum MusicPlaylistLoadAll {
    static let pageLimit = 400
    static func run(_ list: MusicPagedList<MusicTrack>) async -> [MusicTrack] {
        var pages = 0
        while list.hasMore, !list.loadMoreFailed, list.state == .loaded, pages < pageLimit, !Task.isCancelled {
            let before = list.items.count
            await list.loadMore()
            pages += 1
            if list.items.count == before { break }
        }
        let all = list.items, loadedPages = pages
        MusicDebugLog.log("playlist", "loaded all pages: \(all.count) songs after \(loadedPages) more pages")
        return all
    }
}
