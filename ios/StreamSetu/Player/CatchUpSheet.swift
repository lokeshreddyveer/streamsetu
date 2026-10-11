import SwiftUI

/// Earlier programmes of the channel being watched, for providers that keep an archive.
struct CatchUpSheet: View {
    let playback: PlaybackCoordinator
    let channel: Channel
    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var programmes: [EPGProgram] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                if loaded, programmes.isEmpty {
                    EmptyState(symbol: "clock.arrow.circlepath", title: "No earlier programmes", message: "The guide has nothing from the last \(channel.archiveDays) days for this channel.").listRowBackground(Color.clear)
                }
                ForEach(grouped, id: \.day) { group in
                    Section(group.day.formatted(.dateTime.weekday(.wide).day().month())) {
                        ForEach(group.items) { p in
                            Button { playback.playCatchup(channel: channel, program: p); dismiss() } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(p.start.formatted(date: .omitted, time: .shortened)).font(.system(size: 13)).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(p.title).font(.system(size: 15, weight: .medium)).lineLimit(2)
                                        if let d = p.description, !d.isEmpty { Text(d).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2) }
                                    }
                                }
                            }.buttonStyle(.press)
                        }
                    }
                }
            }
            .navigationTitle("Earlier on \(channel.name)").navigationBarTitleDisplayMode(.inline).clearTopBar()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .task { await load() }
    }

    private var grouped: [(day: Date, items: [EPGProgram])] {
        let cal = Calendar.current
        return Dictionary(grouping: programmes) { cal.startOfDay(for: $0.start) }.map { (day: $0.key, items: $0.value.sorted { $0.start < $1.start }) }.sorted { $0.day > $1.day }
    }

    private func load() async {
        guard let c = container else { return }
        let id = channel.id, days = max(1, min(7, channel.archiveDays))
        let now = Date()
        programmes = await Task.detached {
            let all = (try? c.epgRepo.programs(channelIDs: [id], from: now.addingTimeInterval(-Double(days) * 86400), to: now))?[id] ?? []
            return all.filter { $0.end <= now }
        }.value
        loaded = true
    }
}
