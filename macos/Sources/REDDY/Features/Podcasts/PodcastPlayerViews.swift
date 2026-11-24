import SwiftUI

enum PodcastTime {
    static func clock(_ s: TimeInterval) -> String {
        let t = max(0, Int(s)); let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
    static func speed(_ v: Double) -> String { (v == v.rounded() ? String(format: "%.0f", v) : String(format: "%g", v)) + "×" }
}

/// The bottom bar while a podcast plays: audio controls only, never a video thumbnail.
struct PodcastPlayerBar: View {
    let hub: PodcastsHub
    var player: PodcastPlayer { hub.player }
    @Environment(\.reddyAccent) private var accent
    static let height: CGFloat = 84

    var body: some View {
        if let c = player.current {
            HStack(spacing: 16) {
                Button { player.panelOpen = true } label: {
                    HStack(spacing: 10) {
                        ArtworkImage(url: c.artwork?.absoluteString, kind: .poster, contentMode: .fill, symbol: "mic.fill").frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: c.title).font(Typography.bodyMedium).lineLimit(1)
                            Text(verbatim: c.showTitle).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain).frame(width: 270).accessibilityLabel("Open Now Playing").atlas("control.podcasts.nowPlaying")

                VStack(spacing: 6) {
                    HStack(spacing: 22) {
                        Button { player.skipBack() } label: { Image(systemName: "gobackward.\(skip(player.library.skipBack(for: c.feedURL)))").font(.system(size: 18)) }.accessibilityLabel("Back").atlas("control.podcasts.player")
                        Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 34)) }
                            .accessibilityLabel(player.isPlaying ? "Pause" : "Play").keyboardShortcut(.space, modifiers: [.option]).atlas("control.podcasts.player")
                        Button { player.skipForward() } label: { Image(systemName: "goforward.\(skip(player.library.skipForward(for: c.feedURL)))").font(.system(size: 18)) }.accessibilityLabel("Forward").atlas("control.podcasts.player")
                        Button { player.next() } label: { Image(systemName: "forward.end.fill").font(.system(size: 14)) }.disabled(player.library.queue.isEmpty).accessibilityLabel("Next episode").atlas("control.podcasts.player")
                    }
                    .buttonStyle(.plain).foregroundStyle(ColorTokens.textPrimary).atlas("control.podcasts.player")
                    HStack(spacing: 8) {
                        Text(verbatim: PodcastTime.clock(player.position)).font(Typography.timestamp).foregroundStyle(ColorTokens.textSecondary).frame(width: 52, alignment: .trailing)
                        PodcastScrubber(fraction: player.duration > 0 ? player.position / player.duration : 0, onChange: { player.seek(to: $0 * player.duration) }).frame(height: 14)
                        Text(verbatim: "-" + PodcastTime.clock(max(0, player.duration - player.position))).font(Typography.timestamp).foregroundStyle(ColorTokens.textSecondary).frame(width: 56, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 12) {
                    Button { player.cycleSpeed() } label: { Text(verbatim: PodcastTime.speed(player.speed)).font(Typography.bodyMedium).frame(width: 40) }
                        .buttonStyle(.plain).accessibilityLabel("Playback speed").atlas("control.podcasts.speed")
                    PodcastSleepMenu(player: player)
                    Image(systemName: player.volume == 0 ? "speaker.slash" : "speaker.wave.2").font(.system(size: 12)).foregroundStyle(ColorTokens.textSecondary)
                    PodcastScrubber(fraction: player.volume, onChange: { player.volume = $0 }).frame(width: 80, height: 14).accessibilityLabel("Volume")
                    Button { player.panelOpen = true } label: { Image(systemName: "list.bullet") }.buttonStyle(.plain).accessibilityLabel("Up Next and show notes").atlas("control.podcasts.nowPlaying")
                    Button { player.close() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(ColorTokens.textSecondary).accessibilityLabel("Close player").atlas("control.podcasts.player")
                }
            }
            .padding(.horizontal, 18).frame(height: Self.height)
            .background(PodcastBarBackground())
        }
    }
    private func skip(_ s: Int) -> Int { [5, 10, 15, 30, 45, 60, 75, 90].contains(s) ? s : (s < 20 ? 15 : 30) }
}

struct PodcastSleepMenu: View {
    let player: PodcastPlayer
    var body: some View {
        Menu {
            Button("Off") { player.setSleep(.off) }.atlas("control.podcasts.sleep")
            ForEach([5, 10, 15, 30, 45, 60], id: \.self) { m in Button("\(m) minutes") { player.setSleep(.minutes(m)) }.atlas("control.podcasts.sleep") }
            Button("End of Episode") { player.setSleep(.endOfEpisode) }.atlas("control.podcasts.sleep")
        } label: { Image(systemName: player.sleep == .off ? "moon.zzz" : "moon.zzz.fill").foregroundStyle(player.sleep == .off ? ColorTokens.textSecondary : ColorTokens.accentDefault) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Sleep timer").atlas("control.podcasts.sleep")
    }
}

/// The expanded panel: large artwork, show notes, chapters, transcript and the queue. Opens only when asked.
struct PodcastNowPlayingPanel: View {
    let hub: PodcastsHub
    @State private var tab = Tab.notes
    enum Tab: String, CaseIterable { case notes = "Show Notes", chapters = "Chapters", transcript = "Transcript", upNext = "Up Next" }
    var player: PodcastPlayer { hub.player }

    var body: some View {
        if let c = player.current {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    ArtworkImage(url: c.artwork?.absoluteString, kind: .poster, contentMode: .fill, symbol: "mic.fill").frame(width: 260, height: 260).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: ColorTokens.background.opacity(0.7), radius: 16, y: 8)
                    Text(verbatim: c.title).font(Typography.title).lineLimit(3)
                    Text(verbatim: c.showTitle).font(Typography.body).foregroundStyle(ColorTokens.textSecondary)
                    if let ch = player.currentChapter { Label(ch.title, systemImage: "bookmark").font(Typography.caption).foregroundStyle(ColorTokens.accentDefault).lineLimit(2) }
                    PodcastShowSettingsView(hub: hub, feed: c.feedURL)
                }.frame(width: 260)
                VStack(alignment: .leading, spacing: 12) {
                    PodcastSegmented(options: Tab.allCases, selection: $tab) { LocalizedStringKey($0.rawValue) }
                    ScrollView { content(c).frame(maxWidth: .infinity, alignment: .leading) }.scrollIndicators(.hidden)
                }.frame(maxWidth: .infinity)
            }
            .padding(24).frame(height: 540)
        }
    }

    @ViewBuilder private func content(_ c: PodcastEpisodeRef) -> some View {
        switch tab {
        case .notes:
            let s = c.summary
            if s.isEmpty { Text("No show notes.").foregroundStyle(ColorTokens.textSecondary) } else { Text(verbatim: s).font(Typography.body).fixedSize(horizontal: false, vertical: true) }
        case .chapters:
            if player.chapters.isEmpty { Text("This episode has no chapters.").foregroundStyle(ColorTokens.textSecondary) }
            VStack(spacing: 2) {
                ForEach(player.chapters) { ch in
                    Button { player.playChapter(ch) } label: {
                        HStack { Text(verbatim: PodcastTime.clock(ch.start)).font(Typography.timestamp).foregroundStyle(ColorTokens.textSecondary).frame(width: 56, alignment: .leading); Text(verbatim: ch.title).font(Typography.body); Spacer() }
                            .padding(8).background(player.currentChapter == ch ? ColorTokens.accentDefault.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
                    }.buttonStyle(.plain).atlas("control.podcasts.nowPlaying")
                }
            }
        case .transcript:
            if player.transcript.isEmpty { Text("This episode has no transcript.").foregroundStyle(ColorTokens.textSecondary) }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(player.transcript) { l in
                    Button { if let t = l.start { player.seek(to: t) } } label: {
                        HStack(alignment: .top, spacing: 10) {
                            if let t = l.start { Text(verbatim: PodcastTime.clock(t)).font(Typography.timestamp).foregroundStyle(ColorTokens.textSecondary).frame(width: 52, alignment: .leading) }
                            Text(verbatim: l.text).font(Typography.body).multilineTextAlignment(.leading)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).atlas("control.podcasts.nowPlaying")
                }
            }
        case .upNext: PodcastQueueList(hub: hub)
        }
    }
}

/// Per-show speed and skip settings, kept for the show only.
struct PodcastShowSettingsView: View {
    let hub: PodcastsHub
    let feed: URL
    var body: some View {
        let st = hub.library.settings(for: feed)
        VStack(alignment: .leading, spacing: 6) {
            Text("THIS SHOW").font(Typography.eyebrow).tracking(1.2).foregroundStyle(ColorTokens.textTertiary)
            row("Speed", value: PodcastTime.speed(hub.library.speed(for: feed)), choices: PodcastLibrary.speeds.map { ($0, PodcastTime.speed($0)) }) { v in var s = st; s.speed = v; hub.library.setSettings(s, for: feed); hub.player.setSpeed(v) }
            row("Skip back", value: "\(hub.library.skipBack(for: feed)) s", choices: [10, 15, 30, 45].map { (Double($0), "\($0) s") }) { v in var s = st; s.skipBack = Int(v); hub.library.setSettings(s, for: feed) }
            row("Skip forward", value: "\(hub.library.skipForward(for: feed)) s", choices: [15, 30, 45, 60, 90].map { (Double($0), "\($0) s") }) { v in var s = st; s.skipForward = Int(v); hub.library.setSettings(s, for: feed) }
            row("Skip intro", value: "\(st.skipIntro ?? 0) s", choices: [0, 15, 30, 60, 90].map { (Double($0), "\($0) s") }) { v in var s = st; s.skipIntro = v == 0 ? nil : Int(v); hub.library.setSettings(s, for: feed) }
        }
        .font(Typography.caption)
    }
    private func row(_ title: LocalizedStringKey, value: String, choices: [(Double, String)], set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(title).foregroundStyle(ColorTokens.textSecondary)
            Spacer()
            Menu { ForEach(choices, id: \.0) { c in Button(c.1) { set(c.0) }.atlas("control.podcasts.speed") } } label: { Text(verbatim: value) }.menuStyle(.borderlessButton).foregroundStyle(ColorTokens.textPrimary).fixedSize().atlas("control.podcasts.speed")
        }
        .atlas("control.podcasts.speed")
    }
}

/// The Podcasts sidebar: the same rows and selection look as the other sections, in the same width.
struct PodcastsSidebar: View {
    @Bindable var hub: PodcastsHub
    var collapsed = false
    @Environment(\.reddyAccent) private var accent
    @Environment(\.reddyDensity) private var density

    var body: some View {
        VStack(spacing: 1) {
            if !collapsed { Text("PODCASTS").font(Typography.eyebrow).tracking(1.5).foregroundStyle(ColorTokens.textSecondary).frame(maxWidth: .infinity, minHeight: 26, alignment: .leading).padding(.horizontal, 6).padding(.top, 10).padding(.bottom, 6) }
            ForEach(PodcastsSection.allCases) { s in
                let selected = hub.nav.section == s
                Button { hub.select(s) } label: {
                    HStack(spacing: 9) {
                        Image(systemName: s.symbol).font(.system(size: 13)).frame(width: 18)
                        Text(s.title).font(Typography.row).fontWeight(selected ? .semibold : .regular).lineLimit(1)
                        Spacer(minLength: 0)
                        if s == .upNext, !hub.library.queue.isEmpty { Text(verbatim: "\(hub.library.queue.count)").font(Typography.micro).foregroundStyle(ColorTokens.textTertiary) }
                    }
                    .padding(.horizontal, 9).frame(height: density.sidebarRowHeight).frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(selected ? accent : ColorTokens.textSecondary)
                    .background { if selected { RoundedRectangle(cornerRadius: LayoutTokens.radiusSmall, style: .continuous).fill(accent.opacity(0.1)).overlay(alignment: .leading) { Capsule().fill(accent).frame(width: 3).padding(.vertical, 7) } } }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : []).atlas("screen.destination.podcasts")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(width: LayoutTokens.sidebarWidth).frame(maxHeight: .infinity)
        .background(PodcastSidebarBackground())
        .overlay(alignment: .trailing) { Rectangle().fill(ColorTokens.line).frame(width: 1) }
    }
}
