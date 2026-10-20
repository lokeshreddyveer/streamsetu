import WidgetKit
import SwiftUI
import ActivityKit

// MARK: Continue Watching

struct ContinueEntry: TimelineEntry {
    let date: Date
    let items: [WidgetShared.Item]
}

struct ContinueProvider: TimelineProvider {
    func placeholder(in context: Context) -> ContinueEntry { ContinueEntry(date: Date(), items: [.init(title: "Your film", subtitle: "Pick up where you stopped", progress: 0.4, link: "streamsetu://open?tab=home")]) }
    func getSnapshot(in context: Context, completion: @escaping (ContinueEntry) -> Void) { completion(ContinueEntry(date: Date(), items: WidgetShared.load())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ContinueEntry>) -> Void) {
        let entry = ContinueEntry(date: Date(), items: WidgetShared.load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
    }
}

private let ember = Color(red: 1.0, green: 0.42, blue: 0.24)

struct ContinueRow: View {
    let item: WidgetShared.Item
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text(item.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            ProgressView(value: min(max(item.progress, 0), 1)).tint(ember).scaleEffect(x: 1, y: 0.7, anchor: .center)
        }
    }
}

struct ContinueView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ContinueEntry

    var body: some View {
        let shown = Array(entry.items.prefix(family == .systemSmall ? 1 : 3))
        Group {
            if shown.isEmpty {
                VStack(spacing: 6) { Image(systemName: "play.circle.fill").font(.title).foregroundStyle(ember); Text("Nothing to continue").font(.caption).foregroundStyle(.secondary) }
            } else if family == .systemSmall, let first = shown.first {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Continue", systemImage: "play.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(ember)
                    Spacer(minLength: 0)
                    ContinueRow(item: first)
                }.widgetURL(URL(string: first.link))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Continue Watching", systemImage: "play.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(ember)
                    ForEach(shown) { item in
                        if let url = URL(string: item.link) { Link(destination: url) { ContinueRow(item: item) } } else { ContinueRow(item: item) }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .containerBackground(Color(red: 0.03, green: 0.03, blue: 0.05), for: .widget)
    }
}

struct ContinueWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ContinueWatching", provider: ContinueProvider()) { entry in ContinueView(entry: entry) }
            .configurationDisplayName("Continue Watching")
            .description("Pick up the films and episodes you left unfinished.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: Download Live Activity

struct DownloadActivityView: View {
    let state: DownloadActivityAttributes.ContentState
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Image(systemName: "arrow.down.circle.fill").foregroundStyle(ember); Text("Downloading").font(.caption.weight(.semibold)).foregroundStyle(.secondary); Spacer(); Text("\(Int(state.fraction * 100))%").font(.caption.monospacedDigit()) }
            Text(state.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            ProgressView(value: min(max(state.fraction, 0), 1)).tint(ember)
            if state.waiting > 0 { Text("\(state.waiting) more waiting").font(.caption2).foregroundStyle(.secondary) }
        }.padding(14)
    }
}

struct DownloadActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            DownloadActivityView(state: context.state).activityBackgroundTint(Color(red: 0.05, green: 0.05, blue: 0.08))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: "arrow.down.circle.fill").foregroundStyle(ember) }
                DynamicIslandExpandedRegion(.trailing) { Text("\(Int(context.state.fraction * 100))%").monospacedDigit() }
                DynamicIslandExpandedRegion(.center) { Text(context.state.title).lineLimit(1) }
                DynamicIslandExpandedRegion(.bottom) { ProgressView(value: min(max(context.state.fraction, 0), 1)).tint(ember) }
            } compactLeading: {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(ember)
            } compactTrailing: {
                Text("\(Int(context.state.fraction * 100))%").monospacedDigit().font(.caption2)
            } minimal: {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(ember)
            }
        }
    }
}

@main
struct StreamSetuWidgetBundle: WidgetBundle {
    var body: some Widget {
        ContinueWidget()
        DownloadActivityWidget()
    }
}
