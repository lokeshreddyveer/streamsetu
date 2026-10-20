import SwiftUI

/// Tonight: what is on, what is set to record, what to watch next.
struct TonightView: View {
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @State private var plan: TonightPlan?

    var body: some View {
        List {
            if let container { Section { UsualEveningRow(container: container) }.listRowBackground(Color.clear).listRowInsets(EdgeInsets()) }
            if let plan {
                if plan.isEmpty {
                    EmptyState(symbol: "moon.stars", title: "Nothing lined up yet", message: "Favourite a few channels with a guide, follow a series, or add a guide alert, and tonight fills in.").listRowBackground(Color.clear)
                }
                if !plan.onNow.isEmpty { Section("On now") { ForEach(plan.onNow) { s in show(s, live: true) } }.listRowBackground(ColorTokens.surface) }
                if !plan.later.isEmpty { Section("Coming up") { ForEach(plan.later) { s in show(s, live: false) } }.listRowBackground(ColorTokens.surface) }
                if !plan.upNext.isEmpty {
                    Section("Next episode") {
                        ForEach(plan.upNext) { u in
                            Button { container?.playback.play(episode: u.episode, series: u.series) } label: {
                                VStack(alignment: .leading) { Text(u.series.title); Text("S\(u.episode.seasonNumber) E\(u.episode.episodeNumber) · \(u.episode.title)").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }.listRowBackground(ColorTokens.surface)
                }
                if !plan.alerts.isEmpty { Section("From your guide alerts") { ForEach(plan.alerts, id: \.self) { Text($0) } }.listRowBackground(ColorTokens.surface) }
            } else { ProgressView() }
        }
        .navigationTitle("Tonight").themed("Tonight")
        .task(id: "\(state.activeSourceID?.uuidString ?? "")-\(state.catalogVersion)") { await load() }
    }

    private func show(_ s: TonightPlan.Show, live: Bool) -> some View {
        Button { container?.playback.play(channel: s.channel) } label: {
            VStack(alignment: .leading) {
                Text(s.program.title)
                Text("\(s.channel.name) · " + (live ? "until \(TimeFormatter.time(s.program.end))" : TimeFormatter.time(s.program.start))).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func load() async {
        guard let c = container else { return }
        let sid = state.activeSourceID
        let alerts = c.alerts.lastFound
        plan = await Task.detached {
            let now = Date()
            var q = ChannelQuery(); q.sourceID = sid; q.favoritesOnly = true; q.onlyWithGuide = true; q.limit = 60
            let channels = (try? c.catalog.channels(q)) ?? []
            let programs = (try? c.epgRepo.programs(channelIDs: channels.map(\.id), from: now, to: now.addingTimeInterval(TonightBuilder.horizon))) ?? [:]
            let next = (try? c.history.upNext(limit: TonightBuilder.maxUpNext, sourceID: sid)) ?? []
            return TonightBuilder.build(now: now, channels: channels, programs: programs, recordings: [], upNext: next, alerts: alerts)
        }.value
    }
}
