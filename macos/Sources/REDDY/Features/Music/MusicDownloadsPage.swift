import SwiftUI

// Downloads: what is saved for offline listening, what is in progress, and how much space it takes.

enum MusicDownloadStatus: Equatable {
    case waiting, active, done, failed, paused

    /// Reads a state by its name so this screen does not depend on the exact enum the download manager uses.
    static func classify(_ description: String) -> MusicDownloadStatus {
        let s = description.lowercased()
        if s.contains("fail") || s.contains("error") { return .failed }
        if s.contains("complet") || s.contains("done") || s.contains("finish") { return .done }
        if s.contains("paus") { return .paused }
        if s.contains("queue") || s.contains("wait") || s.contains("pending") { return .waiting }
        return .active
    }
    /// The state the download manager reports, read by its type: a new case is a compile error here, not a silent change of meaning.
    static func of(_ state: MusicDownloadItem.State) -> MusicDownloadStatus {
        switch state {
        case .queued: .waiting
        case .resolving, .downloading: .active
        case .paused: .paused
        case .done: .done
        case .failed: .failed
        }
    }
    /// Why a failed download failed, when the manager said.
    static func reason(_ state: MusicDownloadItem.State) -> String? { if case .failed(let r) = state, !r.isEmpty { r } else { nil } }
    var text: String {
        switch self { case .waiting: "Waiting"; case .active: "Downloading"; case .done: "Saved"; case .failed: "Failed"; case .paused: "Paused" }
    }
}

enum MusicDownloadsLogic {
    static func percent(_ progress: Double) -> Int { Int((min(1, max(0, progress.isFinite ? progress : 0)) * 100).rounded()) }
    /// Total size of the given files; missing files count as zero.
    static func totalBytes(_ urls: [URL]) -> Int64 {
        urls.reduce(into: Int64(0)) { sum, u in
            sum += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }
}

struct MusicDownloadsPage: View {
    let hub: MusicHub
    @State private var storageBytes: Int64 = 0
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        let items = hub.downloads.items
        let doneTracks = items.filter { MusicDownloadStatus.of($0.state) == .done }.map(\.track)
        MusicScreen(title: Localized.string("Downloads"), trailing: {
            if !items.isEmpty {
                Text(verbatim: Localized.string("%@ used", MusicTime.bytes(storageBytes))).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary)
                    .accessibilityLabel(Text(verbatim: Localized.string("Storage used %@", MusicTime.bytes(storageBytes))))
            }
        }) {
            if items.isEmpty {
                MusicEmptyState(glyph: .offline, title: Localized.string("Nothing downloaded"), message: Localized.string("Use Download in a track's menu to keep it for offline listening."))
                    .frame(maxWidth: .infinity, minHeight: MusicSpace.huge * 7)
            } else {
                if !doneTracks.isEmpty { HStack(spacing: MusicSpace.sm) { MusicPlayShuffleButtons(hub: hub, tracks: doneTracks, sourceName: Localized.string("Downloads")) } }
                MusicDownloadsGroupedView(hub: hub, items: items, offline: doneTracks) { item, offline in AnyView(row(item, offline: offline)) }
            }
        }
        .task(id: items.count * 100_000 + doneTracks.count) { await refreshStorage() }
    }

    private func row(_ item: MusicDownloadItem, offline: [MusicTrack]) -> some View {
        let status = MusicDownloadStatus.of(item.state)
        let t = item.track
        return HStack(spacing: MusicSpace.sm) {
            MusicArtwork(track: t, size: MusicSpace.huge + MusicSpace.xxs, corner: MusicCorner.control)
            VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                Text(verbatim: t.title).musicText(.card).lineLimit(1)
                Text(verbatim: t.displayArtistLine).musicText(.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
                if status == .failed, let why = MusicDownloadStatus.reason(item.state) {
                    Text(verbatim: why).musicText(.caption).foregroundStyle(ColorTokens.danger).lineLimit(2)
                }
                if status == .active || status == .waiting || status == .paused {
                    ProgressView(value: min(1, max(0, item.progress))).tint(accent).frame(maxWidth: MusicTokens.settingsFieldWidth + MusicSpace.huge)
                }
            }
            Spacer(minLength: 0)
            Text(verbatim: status == .active ? "\(MusicDownloadsLogic.percent(item.progress))%" : Localized.string(status.text))
                .musicText(.caption).foregroundStyle(status == .failed ? ColorTokens.danger : ColorTokens.textSecondary)
            if status == .done {
                MusicIconButton(systemImage: "play.fill", label: Localized.string("Play %@ offline", t.title), atlas: "control.music.downloadsPlayOffline") {
                    if let i = offline.firstIndex(of: t) { hub.play(offline, at: i) }
                }
                MusicIconButton(systemImage: "trash", label: Localized.string("Remove download of %@", t.title), atlas: "control.music.downloadsRemoveDownloadOf") { hub.downloads.remove(item.id) }
            } else {
                MusicIconButton(systemImage: "xmark.circle", label: Localized.string("Cancel download of %@", t.title), atlas: "control.music.downloadsCancelDownloadOf") { hub.downloads.cancel(item.id) }
                if status == .failed {
                    MusicIconButton(systemImage: "arrow.clockwise", label: Localized.string("Try %@ again", t.title), atlas: "control.music.downloadsTryAgain") { hub.downloads.enqueue(t) }
                }
            }
        }
        .padding(.vertical, MusicSpace.xs)
        .accessibilityElement(children: .contain)
    }

    /// File sizes are read off the main actor's busy path: only when the list or a finished download changes.
    private func refreshStorage() async {
        let urls = hub.downloads.items.compactMap { hub.downloads.localURL(for: $0.track) }
        storageBytes = await Task.detached(priority: .utility) { MusicDownloadsLogic.totalBytes(urls) }.value
    }
}
