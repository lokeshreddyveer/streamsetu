import SwiftUI

/// The full-screen channel switcher: every channel in the current list with what is on now and next, so you can change channel
/// without leaving the picture. ↑ ↓ move, Return watches, Esc closes; a click on a row watches it too.
struct ChannelSwitcherPanel: View {
    let playback: PlaybackCoordinator
    @Environment(\.container) private var container
    @State private var guide: [String: [EPGProgram]] = [:]
    @State private var tick = Date()

    private var queue: [Channel] { playback.queue }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Channels").font(.headline)
                Spacer()
                Text("↑ ↓  choose   ⏎  watch   esc  close").font(.caption).foregroundStyle(.white.opacity(0.55))
                Button { playback.closeChannelSwitcher() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 24, height: 24).background(Color.white.opacity(0.1), in: Circle()) }
                    .buttonStyle(.plain).help("Close").accessibilityLabel("Close channel list")
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider().overlay(Color.white.opacity(0.12))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(queue.enumerated()), id: \.element.id) { i, ch in
                            row(ch, index: i).id(ch.id)
                        }
                    }.padding(8)
                }
                .scrollIndicators(.hidden)
                .onChange(of: playback.switcher.selected) { _, i in
                    guard queue.indices.contains(i) else { return }
                    withAnimation(.smooth(duration: 0.18)) { proxy.scrollTo(queue[i].id, anchor: .center) }
                }
                .onAppear { if queue.indices.contains(playback.switcher.selected) { proxy.scrollTo(queue[playback.switcher.selected].id, anchor: .center) } }
            }
        }
        .frame(width: 400)
        .frame(maxHeight: .infinity)
        .background { ZStack { Rectangle().fill(.ultraThinMaterial); Rectangle().fill(Color.black.opacity(0.55)) } }
        .overlay(alignment: .trailing) { Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1) }
        .task(id: loadKey) { await loadGuide() }
        .task { while !Task.isCancelled { try? await Task.sleep(nanoseconds: 30_000_000_000); tick = Date(); await loadGuide() } }
        .accessibilityElement(children: .contain).accessibilityLabel("Channel switcher")
    }

    private var loadKey: String { "\(playback.switcher.window().lowerBound)-\(playback.switcher.window().upperBound)-\(queue.count)" }

    private func row(_ ch: Channel, index: Int) -> some View {
        let selected = index == playback.switcher.selected
        let playing = ch.id == playback.currentChannel?.id
        let now = guide[ch.id]?.first { $0.isLive(at: tick) }
        let next = guide[ch.id]?.first { $0.start > tick }
        return Button {
            playback.highlightChannel(at: index); playback.commitChannelSwitcher()
        } label: {
            HStack(spacing: 12) {
                Text("\(index + 1)").font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(.white.opacity(0.5)).frame(width: 30, alignment: .trailing)
                ChannelLogo(url: ch.logoURL, name: ch.name, size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(ch.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if playing { Text("PLAYING").font(.system(size: 8, weight: .bold)).tracking(0.6).padding(.horizontal, 5).padding(.vertical, 2).background(ColorTokens.accentDefault, in: Capsule()) }
                    }
                    if let now {
                        Text(now.title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                        ProgressView(value: now.progress(at: tick)).progressViewStyle(.linear).tint(ColorTokens.accentDefault).frame(height: 3)
                    } else {
                        Text(guide[ch.id] == nil ? " " : "No guide information").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                    }
                    if let next { Text("Next · \(TimeFormatter.time(next.start)) \(next.title)").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.white.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? ColorTokens.accentDefault.opacity(0.8) : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.white)
        .accessibilityLabel("\(ch.name)\(now.map { ", now \($0.title)" } ?? "")").accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func loadGuide() async {
        guard let c = container else { return }
        let range = playback.switcher.window()
        let ids = range.compactMap { queue.indices.contains($0) ? queue[$0].id : nil }
        guard !ids.isEmpty else { return }
        let found = await Task.detached { (try? c.epgRepo.nowNext(channelIDs: ids, at: Date())) ?? [:] }.value
        for id in ids { guide[id] = found[id] ?? [] }
    }
}
