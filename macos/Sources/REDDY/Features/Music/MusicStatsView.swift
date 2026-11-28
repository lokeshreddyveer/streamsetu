import SwiftUI
import Charts

// Listening stats for Music: counted on this device, nothing is sent anywhere. Shown inside the Statistics page (Music segment) and usable on its own.

// MARK: - Pure helpers (tested)

enum MusicStatsFormat {
    /// Narrow units: "42h 17m". Minutes are rounded; from 100 hours only hours; under a minute "0m".
    static func duration(_ secs: Int) -> String {
        let mins = Int((Double(secs) / 60).rounded())
        guard mins >= 1 else { return "0m" }
        let h = mins / 60, m = mins % 60
        if h >= 100 { return "\(h)h" }
        if h > 0 { return m == 0 ? "\(h)h" : "\(h)h \(m)m" }
        return "\(m)m"
    }

    static func hourLabel(_ h: Int) -> String { String(format: "%02d:00", h) }
    static let daypartNames = ["Morning", "Afternoon", "Evening", "Night"]
    static let daypartRanges = [(5, 12), (12, 17), (17, 22), (22, 5)]
    static let personas = ["Early bird", "Afternoon listener", "Evening listener", "Night owl"]
}

struct MusicStatsBar: Hashable, Sendable, Identifiable {
    var index: Int
    var date: Date
    var secs: Int
    var id: Int { index }
}

enum MusicStatsChartData {
    /// One bar per day for 7 and 30 days (zero days included), one per month for 12 months, and for All time when the history is longer than 92 days.
    static func bars(_ r: MusicStatsReport, range: MusicStatsRange, now: Date, calendar: Calendar = .current) -> (bars: [MusicStatsBar], monthly: Bool) {
        let today = calendar.startOfDay(for: now)
        func date(_ day: Int) -> Date { calendar.date(byAdding: .day, value: day - r.todayDay, to: today) ?? today }
        let firstDay = r.windowStartDay ?? r.days.keys.min() ?? r.todayDay
        let startDay = min(firstDay, r.todayDay)
        let span = r.todayDay - startDay + 1
        let monthly = range == .year || (range == .all && span > 92)
        guard monthly else {
            return ((0..<span).map { i in let d = startDay + i; return MusicStatsBar(index: i, date: date(d), secs: r.days[d] ?? 0) }, false)
        }
        var months: [Date: Int] = [:]
        for (d, s) in r.days where d >= startDay { months[monthStart(date(d), calendar), default: 0] += s }
        var cursor = monthStart(date(startDay), calendar)
        let last = monthStart(today, calendar)
        var out: [MusicStatsBar] = []
        while cursor <= last {
            out.append(MusicStatsBar(index: out.count, date: cursor, secs: months[cursor] ?? 0))
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        return (out, true)
    }

    private static func monthStart(_ d: Date, _ c: Calendar) -> Date { c.date(from: c.dateComponents([.year, .month], from: d)) ?? d }

    /// Labels roughly every ceil(n/7) bars for days or ceil(n/12) for months, counted back from the newest so the newest bar is always labelled.
    static func labelled(count n: Int, monthly: Bool) -> [Int] {
        guard n > 0 else { return [] }
        let step = max(1, Int((Double(n) / (monthly ? 12 : 7)).rounded(.up)))
        return (0..<n).filter { (n - 1 - $0) % step == 0 }
    }
}

// MARK: - View

@MainActor
struct MusicStatsView: View {
    let stats: MusicStats
    var onPlay: (([MusicTrack], Int) -> Void)? = nil
    var onOpenArtist: ((MusicTopArtist) -> Void)? = nil
    var onClear: (() -> Void)? = nil

    @Environment(\.reddyAccent) private var accent
    @Environment(\.calendar) private var calendar
    @State private var range = MusicStatsRange.month
    @State private var report: MusicStatsReport?
    @State private var confirmClear = false
    @State private var now = Date()
    @State private var genres: [MusicInsightShare] = []
    @State private var languages: [MusicInsightShare] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let r = report {
                if !stats.hasAnyPlays { empty } else { content(r) }
            } else { MusicLoadingIcon(size: MusicIconSize.small) }
        }
        .task(id: "\(range.rawValue)-\(stats.revision)") { await load() }
        .atlasScreen("screen.music.stats")
        .confirmationDialog("Clear listening history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear Listening History", role: .destructive) { stats.clear(); onClear?() }.atlas("control.music.statisticsClearListeningHistory")
        } message: { Text("Deletes every counted play on this device. On Repeat is emptied too. Your library and playlists are not changed.") }
    }

    private func load() async {
        let file = stats.file, r = range, cal = stats.calendar, at = Date()
        now = at
        report = await Task.detached(priority: .userInitiated) { MusicStatsEngine.report(file, since: r.start(now: at, calendar: cal), now: at, calendar: cal) }.value
        let mix = await Task.detached(priority: .userInitiated) { () -> ([MusicInsightShare], [MusicInsightShare]) in
            let s = MusicInsightsEngine.songs(file, start: r.start(now: at, calendar: cal) ?? .distantPast, end: at.addingTimeInterval(3600), calendar: cal).songs
            return (MusicInsightsEngine.genres(s), MusicInsightsEngine.languages(s))
        }.value
        genres = mix.0; languages = mix.1
    }

    private var empty: some View {
        VStack(spacing: 6) {
            EmptyStateView(symbol: "chart.bar", title: "Your stats start here", message: "Listen to some music and your time, favourites and habits appear here. Plays are counted on this device and nothing is sent anywhere.")
        }.frame(height: 260)
    }

    // MARK: content

    @ViewBuilder private func content(_ r: MusicStatsReport) -> some View {
        header(r)
        tiles(r)
        activity(r)
        if r.plays > 0 {
            HStack(alignment: .top, spacing: 12) { topArtists(r); topSongs(r) }
            if !r.topAlbums.isEmpty { topAlbums(r) }
            whenYouListen(r)
            MusicTasteMixPanels(genres: genres, languages: languages)
        }
        MusicRecapView(stats: stats, onPlay: onPlay)
        footer
    }

    private func header(_ r: MusicStatsReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if r.firstAt != nil {
                Picker("Range", selection: $range) { ForEach(MusicStatsRange.allCases) { Text($0.title.loc).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize().atlas("control.music.statisticsRange")
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(MusicStatsFormat.duration(r.totalSecs)).font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                if let pct = r.changePercent { changeChip(pct) }
            }
            Text(caption(r)).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func caption(_ r: MusicStatsReport) -> String {
        switch range {
        case .week: String(localized: "listened in the last 7 days")
        case .month: String(localized: "listened in the last 30 days")
        case .year: String(localized: "listened in the last 12 months")
        case .all: r.firstAt.map { String(localized: "listened since \($0.formatted(date: .long, time: .omitted))") } ?? String(localized: "listened")
        }
    }

    /// A rise is tinted with the accent; a drop is deliberately quiet, not red.
    private func changeChip(_ pct: Int) -> some View {
        let label = (pct > 0 ? "+" : "") + "\(pct)%"
        let than = range == .year ? String(localized: "vs. the 12 months before") : String(localized: "vs. the \(range == .week ? 7 : 30) days before")
        return Text("\(label) \(than)").font(Typography.captionMedium)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(pct > 0 ? accent.opacity(0.18) : Color.primary.opacity(0.08)))
            .foregroundStyle(pct > 0 ? accent : ColorTokens.textSecondary)
    }

    private func tiles(_ r: MusicStatsReport) -> some View {
        HStack(spacing: 12) {
            tile("Plays", "\(r.plays)", nil)
            tile("Songs", "\(r.songs)", range != .all && r.newSongs > 0 ? String(localized: "\(r.newSongs) new") : nil)
            tile("Artists", "\(r.artists)", nil)
            tile("Day streak", "\(r.currentStreak)", r.bestStreak > r.currentStreak ? String(localized: "Best: \(r.bestStreak)") : nil)
        }
    }

    private func tile(_ title: String, _ value: String, _ hint: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.loc).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
            Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit()
            if let hint { Text(hint).font(Typography.caption).foregroundStyle(accent) }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).surface()
        .accessibilityElement(children: .combine)
    }

    // MARK: activity

    private func activity(_ r: MusicStatsReport) -> some View {
        let data = MusicStatsChartData.bars(r, range: range, now: now, calendar: calendar)
        let bars = data.bars
        let peak = bars.map(\.secs).max() ?? 0
        let labels = Set(MusicStatsChartData.labelled(count: bars.count, monthly: data.monthly))
        let busiest = bars.max { $0.secs < $1.secs }
        return panel("Activity") {
            HStack(spacing: 24) {
                fact(data.monthly ? "Monthly average" : "Daily average", MusicStatsFormat.duration(bars.isEmpty ? 0 : r.totalSecs / bars.count))
                if let b = busiest, b.secs > 0 {
                    fact(data.monthly ? "Busiest month" : "Busiest day", "\(b.date.formatted(data.monthly ? .dateTime.month(.abbreviated).year() : .dateTime.month(.abbreviated).day())), \(MusicStatsFormat.duration(b.secs))")
                }
            }
            Chart(bars) { b in
                BarMark(x: .value("When", b.index), y: .value("Time", b.secs), width: .ratio(bars.count > 40 ? 0.8 : 0.7))
                    .cornerRadius(bars.count > 40 ? 2 : 5)
                    .foregroundStyle(accent.opacity(b.secs == peak && peak > 0 ? 1 : 0.55))
                    .accessibilityLabel(b.date.formatted(date: .long, time: .omitted))
                    .accessibilityValue(MusicStatsFormat.duration(b.secs))
            }
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: bars.count)) { v in
                    if let i = v.as(Int.self), labels.contains(i), bars.indices.contains(i) {
                        AxisValueLabel { Text(bars[i].date, format: data.monthly ? .dateTime.month(.abbreviated) : .dateTime.day()).font(.system(size: 9)) }
                    }
                }
            }
            .frame(height: 150)
            .animation(.easeOut(duration: 0.45), value: bars)
            if r.plays == 0 { Text("Nothing played in this period.").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary) }
        }
    }

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.loc).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
            Text(value).font(Typography.bodyMedium).monospacedDigit()
        }
    }

    // MARK: top lists

    private func topArtists(_ r: MusicStatsReport) -> some View {
        panel("Top artists") {
            if let hero = r.topArtists.first {
                Button { onOpenArtist?(hero) } label: {
                    HStack(spacing: 14) {
                        MusicArtwork(hero.thumbnails, size: 72, corner: 36, subject: .person(hero.name))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("01").font(Typography.mono).foregroundStyle(accent)
                            Text(hero.name).font(Typography.heading).lineLimit(1)
                            Text("\(MusicStatsFormat.duration(hero.secs)) · \(hero.plays) plays · \(r.totalSecs > 0 ? Int((Double(hero.secs) / Double(r.totalSecs) * 100).rounded()) : 0)%")
                                .font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                        }
                    }
                }.buttonStyle(.plain).disabled(onOpenArtist == nil || hero.linkedID == nil).atlas("control.music.statistics01")
                ForEach(Array(r.topArtists.dropFirst().enumerated()), id: \.element.id) { i, a in
                    Button { onOpenArtist?(a) } label: {
                        HStack(spacing: 8) {
                            Text(String(format: "%02d", i + 2)).font(Typography.mono).foregroundStyle(ColorTokens.textTertiary).frame(width: 22, alignment: .trailing)
                            MusicArtwork(a.thumbnails, size: 26, corner: 13, subject: .person(a.name))
                            Text(a.name).font(Typography.row).lineLimit(1).frame(width: 110, alignment: .leading)
                            GeometryReader { g in
                                Capsule().fill(accent.opacity(0.5)).frame(width: g.size.width * CGFloat(Double(a.secs) / Double(max(1, hero.secs))), height: 5).frame(maxHeight: .infinity)
                            }.frame(height: 14)
                            Text(MusicStatsFormat.duration(a.secs)).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).monospacedDigit().frame(width: 60, alignment: .trailing)
                        }
                    }.buttonStyle(.plain).disabled(onOpenArtist == nil || a.linkedID == nil).atlas("control.music.statisticsMusicstatsviewtopartistsButton")
                }
            }
        }
    }

    private func topSongs(_ r: MusicStatsReport) -> some View {
        panel("Top songs") {
            ForEach(Array(r.topSongs.enumerated()), id: \.element.id) { i, s in
                Button { onPlay?(r.topSongs.map(\.track), i) } label: {
                    HStack(spacing: 8) {
                        Text("\(i + 1)").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary).frame(width: 18, alignment: .trailing)
                        MusicArtwork(track: s.track, size: 28, corner: 5)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(s.track.title).font(Typography.row).lineLimit(1)
                            Text(s.track.displayArtistLine).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Text("\(s.plays)").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).monospacedDigit()
                            .accessibilityLabel("\(s.plays) plays")
                    }
                }.buttonStyle(.plain).disabled(onPlay == nil).atlas("control.music.statisticsPlays")
            }
        }
    }

    private func topAlbums(_ r: MusicStatsReport) -> some View {
        panel("Top albums") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(r.topAlbums) { a in
                        VStack(alignment: .leading, spacing: 4) {
                            MusicArtwork(a.thumbnails, size: 110, corner: 8, subject: .album(a.title))
                            Text(a.title).font(Typography.rowMedium).lineLimit(1)
                            Text("\(a.artist) · \(MusicStatsFormat.duration(a.secs))").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
                        }.frame(width: 110, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    // MARK: when you listen

    private func whenYouListen(_ r: MusicStatsReport) -> some View {
        let parts = r.dayparts
        let total = max(1, parts.reduce(0, +))
        let top = parts.indices.max { parts[$0] < parts[$1] } ?? 0
        let colors: [Color] = [accent, accent.opacity(0.75), accent.opacity(0.5), accent.opacity(0.28)]
        return panel("When you listen") {
            HStack(alignment: .center, spacing: 22) {
                Chart(Array(parts.enumerated()), id: \.offset) { i, v in
                    SectorMark(angle: .value("Time", max(v, 0)), innerRadius: .ratio(0.62), angularInset: 1.5).cornerRadius(5).foregroundStyle(colors[i])
                }
                .chartLegend(.hidden)
                .frame(width: 150, height: 150)
                .overlay {
                    VStack(spacing: 0) {
                        Text("\(Int((Double(parts[top]) / Double(total) * 100).rounded()))%").font(.system(size: 20, weight: .semibold)).monospacedDigit()
                        Text(MusicStatsFormat.daypartNames[top].loc).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(MusicStatsFormat.daypartNames[top]), \(Int((Double(parts[top]) / Double(total) * 100).rounded())) percent")
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(0..<4, id: \.self) { i in
                        HStack(spacing: 6) {
                            Circle().fill(colors[i]).frame(width: 8, height: 8)
                            Text(MusicStatsFormat.daypartNames[i].loc).font(Typography.row)
                            Spacer(minLength: 8)
                            Text("\(Int((Double(parts[i]) / Double(total) * 100).rounded()))%").font(Typography.row).foregroundStyle(ColorTokens.textSecondary).monospacedDigit()
                        }
                    }
                    let range = MusicStatsFormat.daypartRanges[top]
                    let hours = MusicStatsFormat.hourLabel(range.0) + "\u{2013}" + MusicStatsFormat.hourLabel(range.1)
                    Text(MusicStatsFormat.personas[top].loc).font(Typography.bodyMedium).padding(.top, 4)
                    Text("Your peak listening hours: \(hours)").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                }.frame(maxWidth: 260)
            }
            heatmap(r)
            HStack(spacing: 24) {
                if let d = r.busiestWeekday { fact("Busiest day of the week", calendar.weekdaySymbols[d]) }
                if let h = r.busiestHour { fact("Busiest hour", MusicStatsFormat.hourLabel(h)) }
            }
        }
    }

    private func heatmap(_ r: MusicStatsReport) -> some View {
        let rows = [1, 2, 3, 4, 5, 6, 0]            // Monday first
        let shades: [Double] = [0.07, 0.25, 0.45, 0.7, 1]
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(rows, id: \.self) { wd in
                HStack(spacing: 3) {
                    Text(calendar.shortWeekdaySymbols[wd]).font(.system(size: 9)).foregroundStyle(ColorTokens.textTertiary).frame(width: 30, alignment: .leading)
                    ForEach(0..<24, id: \.self) { h in
                        RoundedRectangle(cornerRadius: 2).fill(accent.opacity(shades[r.heatLevel(weekday: wd, hour: h)]))
                            .aspectRatio(1, contentMode: .fit)
                            .help("\(calendar.weekdaySymbols[wd]), \(MusicStatsFormat.hourLabel(h)), \(MusicStatsFormat.duration(r.hours[wd][h]))")
                            .accessibilityHidden(true)
                    }
                }
            }
            HStack(spacing: 4) {
                Text("Less").font(.system(size: 9)).foregroundStyle(ColorTokens.textTertiary)
                ForEach(0..<5, id: \.self) { RoundedRectangle(cornerRadius: 2).fill(accent.opacity(shades[$0])).frame(width: 10, height: 10) }
                Text("More").font(.system(size: 9)).foregroundStyle(ColorTokens.textTertiary)
            }.padding(.top, 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Listening heatmap by weekday and hour")
    }

    // MARK: pieces

    private var footer: some View {
        HStack {
            Text("Counted on this device from what you play. Nothing is sent anywhere.").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
            Spacer()
            Button(role: .destructive) { confirmClear = true } label: { Label("Clear listening history", systemImage: "trash") }.musicButton(.destructive, size: .compact).disabled(!stats.hasAnyPlays).atlas("control.music.statisticsClearListeningHistory")
        }
    }

    private func panel<C: View>(_ title: String, @ViewBuilder _ body: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.loc).font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
            body()
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).surface()
    }
}
