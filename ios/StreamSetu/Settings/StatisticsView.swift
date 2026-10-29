import SwiftUI
import Charts

/// What has been watched, worked out on this device from the playback log. Nothing is sent anywhere.
struct StatisticsView: View {
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @State private var range = Range.month
    @State private var stats: ViewingStatistics?
    @State private var confirmReset = false

    enum Range: String, CaseIterable, Identifiable {
        case week = "7 days", month = "30 days", all = "All time"
        var id: Self { self }
        var since: Date? { switch self { case .week: Date().addingTimeInterval(-7 * 86400); case .month: Date().addingTimeInterval(-30 * 86400); case .all: nil } }
    }

    var body: some View {
        List {
            if let container { Section { WeeklyDigestCard(container: container) }.listRowBackground(Color.clear).listRowInsets(EdgeInsets()) }
            Section { Picker("Range", selection: $range) { ForEach(Range.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).listRowBackground(Color.clear) }.listRowBackground(ColorTokens.surface)
            if let s = stats {
                if s.isEmpty {
                    EmptyState(symbol: "chart.bar", title: "Nothing to show yet", message: "Watch something and your viewing time appears here. It stays on this device.").listRowBackground(Color.clear)
                } else {
                    Section {
                        LabeledContent("Watched", value: Self.duration(s.totalSeconds))
                        LabeledContent("Sessions", value: "\(s.sessions)")
                        LabeledContent("Average session", value: Self.duration(s.averageSession))
                        LabeledContent("Longest session", value: Self.duration(s.longestSession))
                        if let h = s.busiestHour { LabeledContent("Busiest hour", value: String(format: "%02d:00", h)) }
                    }.listRowBackground(ColorTokens.surface)
                    Section("Last 14 days") {
                        Chart(s.days, id: \.date) { d in BarMark(x: .value("Day", d.date, unit: .day), y: .value("Minutes", d.seconds / 60)).foregroundStyle(ColorTokens.accentDefault) }
                            .chartYAxisLabel("minutes").frame(height: 150)
                    }.listRowBackground(ColorTokens.surface)
                    Section("By type") {
                        LabeledContent("Live TV", value: Self.duration(s.liveSeconds))
                        LabeledContent("Movies", value: Self.duration(s.movieSeconds))
                        LabeledContent("Series", value: Self.duration(s.seriesSeconds))
                    }.listRowBackground(ColorTokens.surface)
                    top("Top channels", s.topChannels); top("Top movies", s.topMovies); top("Top series", s.topSeries)
                    Section { Button("Reset Statistics", role: .destructive) { confirmReset = true } }.listRowBackground(ColorTokens.surface)
                }
            } else { ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear) }
        }
        .navigationTitle("Statistics").themed("Statistics")
        .task(id: range) { await load() }
        .confirmationDialog("Reset viewing statistics?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset Statistics", role: .destructive) {
                do { try container?.statistics.clear(); stats = ViewingStatistics() }
                catch { state.toasts.show("Could not reset the statistics: \(error.localizedDescription)", symbol: "exclamationmark.triangle") }
            }
        } message: { Text("Deletes the playback log these figures come from. Favourites, history and resume points stay.") }
    }

    @ViewBuilder private func top(_ title: String, _ items: [ViewingStatistics.Top]) -> some View {
        if !items.isEmpty {
            Section(title) { ForEach(Array(items.enumerated()), id: \.element.id) { i, t in LabeledContent("\(i + 1). \(t.title)", value: Self.duration(t.seconds)) } }.listRowBackground(ColorTokens.surface)
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
}
