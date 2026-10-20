import SwiftUI

/// Tonight: what is on, what is set to record, what to watch next.
struct TonightPage: View {
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @State private var plan: TonightPlan?

    var body: some View {
        PageScroll(title: "Tonight") {
            if let plan {
                if plan.isEmpty {
                    EmptyStateView(symbol: "moon.stars", title: "Nothing lined up yet", message: "Favourite a few channels with a guide, follow a series, or add a guide alert, and tonight fills in.").frame(height: 260)
                } else {
                    section("On now", plan.onNow.map { show($0, live: true) })
                    section("Coming up", plan.later.map { show($0, live: false) })
                    if !plan.recordings.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: "Recording")
                            ForEach(plan.recordings) { r in row(symbol: "record.circle", title: r.title, detail: "\(r.channelName) · \(TimeFormatter.time(r.start))") }
                        }
                    }
                    if !plan.upNext.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: "Next episode")
                            ForEach(plan.upNext) { u in
                                Button { container?.playback.play(episode: u.episode, series: u.series) } label: {
                                    row(symbol: "play.circle", title: u.series.title, detail: "S\(u.episode.seasonNumber) E\(u.episode.episodeNumber) · \(u.episode.title)")
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    if !plan.alerts.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: "From your guide alerts")
                            ForEach(plan.alerts, id: \.self) { row(symbol: "bell.badge", title: $0, detail: nil) }
                        }
                    }
                }
            } else { ProgressView().controlSize(.small) }
        }
        .task(id: "\(state.activeSourceID?.uuidString ?? "")-\(state.catalogVersion)") { await load() }
    }

    @ViewBuilder private func section(_ title: String, _ rows: [AnyView]) -> some View {
        if !rows.isEmpty { VStack(alignment: .leading, spacing: 8) { SectionHeader(title: title); ForEach(rows.indices, id: \.self) { rows[$0] } } }
    }

    private func show(_ s: TonightPlan.Show, live: Bool) -> AnyView {
        AnyView(Button { container?.playback.play(channel: s.channel) } label: {
            row(symbol: live ? "dot.radiowaves.left.and.right" : "clock", title: s.program.title,
                detail: "\(s.channel.name) · " + (live ? "until \(TimeFormatter.time(s.program.end))" : TimeFormatter.time(s.program.start)))
        }.buttonStyle(.plain))
    }

    private func row(symbol: String, title: String, detail: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(ColorTokens.accentDefault)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typography.rowMedium).lineLimit(1)
                if let detail { Text(detail).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1) }
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous)).contentShape(Rectangle())
    }

    private func load() async {
        guard let c = container else { return }
        let sid = state.activeSourceID
        let recordings = recordingRows(c)
        let alerts = c.alerts.lastFound
        plan = await Task.detached {
            let now = Date()
            var q = ChannelQuery(); q.sourceID = sid; q.favoritesOnly = true; q.onlyWithGuide = true; q.limit = 60
            let channels = (try? c.catalog.channels(q)) ?? []
            let programs = (try? c.epgRepo.programs(channelIDs: channels.map(\.id), from: now, to: now.addingTimeInterval(TonightBuilder.horizon))) ?? [:]
            let next = (try? c.history.upNext(limit: TonightBuilder.maxUpNext, sourceID: sid)) ?? []
            return TonightBuilder.build(now: now, channels: channels, programs: programs, recordings: recordings, upNext: next, alerts: alerts)
        }.value
    }

    @MainActor private func recordingRows(_ c: AppContainer) -> [TonightPlan.Recording] {
        #if os(macOS)
        return c.scheduledRecordings.items.filter { $0.state == .scheduled || $0.state == .recording }.map { .init(id: $0.id.uuidString, title: $0.title, channelName: $0.channelName, start: $0.start) }
        #else
        return []
        #endif
    }
}
