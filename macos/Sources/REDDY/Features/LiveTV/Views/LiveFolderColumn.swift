import SwiftUI

/// The channel column in Folders mode: Favourites and Recently Watched first (with what is on now and how far along it is), then the folders, 20 at a time.
/// A folder opens as the ordinary channel list (same order, keyboard and zapping as before); channels are never shuffled here.
struct LiveFolderColumn: View {
    let play: (Channel) -> Void
    let currentID: String?
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @Environment(AppRouter.self) private var router
    @State private var model = FolderRowsModel(kind: .channel)

    private var reloadKey: String { "\(state.activeSourceID?.uuidString ?? "")-\(state.catalogVersion)-\(container?.parental.restrictionRevision ?? 0)-\(container?.profiles.activeID ?? "")" }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if !model.loaded {
                    ForEach(0..<8, id: \.self) { _ in SkeletonBlock(height: 34, radius: 7) }
                } else {
                    ForEach(model.visible) { row in
                        if row.special != nil { special(row) } else { folder(row) }
                    }
                    if model.hasMore { ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(8).onAppear { model.more() } }
                }
            }.padding(.horizontal, 6).padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
        .task(id: reloadKey) { if let c = container { await model.reload(c, sourceID: state.activeSourceID, profile: c.profiles.activeID, restrictionKey: "\(c.parental.restrictionRevision)-\(c.profiles.activeID)-\(state.activeSourceID?.uuidString ?? "")") } }
    }

    private func special(_ row: FolderRowsModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.display).font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary).padding(.horizontal, 8).padding(.top, 6).accessibilityAddTraits(.isHeader)
            ForEach((model.channelTiles[row.id] ?? []).prefix(6)) { ch in
                Button { play(ch) } label: { channelRow(ch) }.buttonStyle(.plain)
                    .accessibilityLabel("\(ch.name)\(model.onNow[ch.id].map { ", now \($0.title)" } ?? "")")
                    .accessibilityAddTraits(currentID == ch.id ? .isSelected : [])
            }
        }
        .task(id: "\(model.epoch)-\(row.id)-\(row.locked)") { if let c = container { await model.ensureTiles(row, c, sourceID: state.activeSourceID, profile: c.profiles.activeID) } }
    }

    private func channelRow(_ ch: Channel) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 10) {
                ChannelLogo(url: ch.logoURL, name: ch.name, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ch.name).font(Typography.rowMedium).lineLimit(1)
                    if let p = model.onNow[ch.id] { Text(p.title).font(.system(size: 10)).foregroundStyle(ColorTokens.textSecondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
                if currentID == ch.id { Image(systemName: "waveform").font(.system(size: 11)).foregroundStyle(ColorTokens.accentDefault) }
            }
            if let p = model.onNow[ch.id] {
                let total = max(1, p.end.timeIntervalSince(p.start)), done = min(1, max(0, Date().timeIntervalSince(p.start) / total))
                ProgressView(value: done).progressViewStyle(.linear).tint(ColorTokens.accentDefault).scaleEffect(y: 0.6).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4).contentShape(Rectangle())
    }

    private func folder(_ row: FolderRowsModel.Row) -> some View {
        Button { router.select(.folder(row.id)) } label: {
            HStack(spacing: 8) {
                Image(systemName: row.locked ? "lock.fill" : "folder").font(.system(size: 12)).foregroundStyle(ColorTokens.textSecondary).frame(width: 18)
                Text(row.display).font(Typography.rowMedium).lineLimit(1)
                Spacer(minLength: 4)
                if !row.locked { Text(row.count.formatted()).font(Typography.caption).monospacedDigit().foregroundStyle(ColorTokens.textTertiary) }
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(ColorTokens.textTertiary)
            }
            .padding(.horizontal, 10).frame(height: 34).contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusable()
        .accessibilityLabel(row.locked ? "\(row.display), locked folder" : "\(row.display), \(row.count) channels")
        .onAppear { if row.id == model.visible.last?.id { model.more() } }
    }
}
