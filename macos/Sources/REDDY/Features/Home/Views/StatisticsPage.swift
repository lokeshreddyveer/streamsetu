import SwiftUI

/// Viewing statistics, worked out on this Mac from the playback log. Nothing is sent anywhere.
struct StatisticsPage: View {
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @Environment(\.reddyAccent) private var accent
    @State private var range = Range.month
    @State private var stats: ViewingStatistics?
    @State private var confirmReset = false

    enum Range: String, CaseIterable, Identifiable {
        case week = "7 days", month = "30 days", all = "All time"
        var id: Self { self }
        var since: Date? {
            switch self {
            case .week: Date().addingTimeInterval(-7 * 86400)
            case .month: Date().addingTimeInterval(-30 * 86400)
            case .all: nil
            }
        }
    }

    var body: some View {
        PageScroll(title: "Statistics", trailing: AnyView(controls)) {
            if let container { WeeklyDigestCard(container: container) }
            if let s = stats {
                if s.isEmpty {
                    EmptyStateView(symbol: "chart.bar", title: "Nothing to show yet", message: "Watch something and your viewing time appears here. It stays on this Mac.").frame(height: 260)
                } else { content(s) }
            } else { ProgressView().controlSize(.small) }
        }
        .task(id: "\(range.rawValue)-\(state.catalogVersion)") { await load() }
        .confirmationDialog("Reset viewing statistics?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset Statistics", role: .destructive) { reset() }
        } message: { Text("Deletes the playback log these figures are built from. Watch history, favourites and resume points are not changed.") }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("Range", selection: $range) { ForEach(Range.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            Button { confirmReset = true } label: { Label("Reset", systemImage: "trash") }.disabled(stats?.isEmpty ?? true)
        }
    }

    @ViewBuilder private func content(_ s: ViewingStatistics) -> some View {
        HStack(spacing: 12) {
            tile("Watched", Self.duration(s.totalSeconds))
            tile("Sessions", "\(s.sessions)")
            tile("Average session", Self.duration(s.averageSession))
            tile("Longest session", Self.duration(s.longestSession))
            if let h = s.busiestHour { tile("Busiest hour", String(format: "%02d:00", h)) }
        }
        panel("Last 14 days") { dayChart(s) }
        panel("By type") {
            VStack(spacing: 8) {
                bar("Live TV", s.liveSeconds, of: s.totalSeconds)
                bar("Movies", s.movieSeconds, of: s.totalSeconds)
                bar("Series", s.seriesSeconds, of: s.totalSeconds)
            }
        }
        HStack(alignment: .top, spacing: 12) {
            topList("Top channels", s.topChannels)
            topList("Top movies", s.topMovies)
            topList("Top series", s.topSeries)
        }
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.loc).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
            Text(value).font(.system(size: 20, weight: .semibold)).monospacedDigit()
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).surface()
        .accessibilityElement(children: .combine)
    }

    private func panel<C: View>(_ title: String, @ViewBuilder _ body: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold))
            body()
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).surface()
    }

    private func dayChart(_ s: ViewingStatistics) -> some View {
        let peak = max(s.days.map(\.seconds).max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(s.days, id: \.date) { d in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(d.seconds > 0 ? accent : ColorTokens.line)
                        .frame(height: max(3, 90 * d.seconds / peak))
                    Text(d.date, format: .dateTime.day()).font(.system(size: 9)).foregroundStyle(ColorTokens.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .help("\(d.date.formatted(date: .abbreviated, time: .omitted)): \(Self.duration(d.seconds))")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(d.date.formatted(date: .abbreviated, time: .omitted)), \(Self.duration(d.seconds))")
            }
        }
        .frame(height: 116, alignment: .bottom)
    }

    private func bar(_ title: String, _ seconds: TimeInterval, of total: TimeInterval) -> some View {
        HStack(spacing: 10) {
            Text(title.loc).font(Typography.row).frame(width: 70, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(ColorTokens.line)
                    Capsule().fill(accent).frame(width: g.size.width * (total > 0 ? min(1, seconds / total) : 0))
                }
            }.frame(height: 6)
            Text(Self.duration(seconds)).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).monospacedDigit().frame(width: 80, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func topList(_ title: String, _ items: [ViewingStatistics.Top]) -> some View {
        panel(title) {
            if items.isEmpty { Text("Nothing yet").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary) }
            else {
                VStack(spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                        HStack(spacing: 8) {
                            Text("\(i + 1)").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary).frame(width: 16, alignment: .trailing)
                            Text(t.title).font(Typography.row).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(Self.duration(t.seconds)).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let m = Int((seconds / 60).rounded())
        if m < 1 { return seconds >= 1 ? "<1 min" : "0 min" }
        return m < 60 ? "\(m) min" : m < 1440 ? "\(m / 60) h \(m % 60) min" : "\(m / 1440) d \((m % 1440) / 60) h"
    }

    private func load() async {
        guard let svc = container?.statistics else { return }
        let since = range.since
        stats = await Task.detached { (try? svc.compute(since: since)) ?? ViewingStatistics() }.value
    }

    private func reset() {
        try? container?.statistics.clear()
        stats = ViewingStatistics()
    }
}
