import SwiftUI

/// "Now playing" details under the player: current and upcoming programs, with reminders for future ones.
struct CurrentProgramCard: View {
    let channel: Channel
    let upcoming: [EPGProgram]
    /// Programmes already aired and still in the provider's archive, newest first, with what to do when one is chosen.
    var past: [EPGProgram] = []
    var onCatchup: (EPGProgram) -> Void = { _ in }
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @Environment(AppSettings.self) private var settings
    @State private var reminded: Set<Int64> = []

    private var now: EPGProgram? { upcoming.first { $0.isLive() } }
    private var later: [EPGProgram] { upcoming.filter { $0.start > Date() }.prefix(6).map { $0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("NOW PLAYING").font(Typography.micro).tracking(1.5).foregroundStyle(ColorTokens.textSecondary)
            HStack(spacing: Spacing.md) {
                ChannelLogo(url: channel.logoURL, name: channel.name, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name).font(Typography.heading)
                    Text(channel.categoryName ?? "").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                }
            }
            if let p = now {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(TimeFormatter.time(p.start)) — \(p.title)").font(Typography.bodyMedium)
                    if let s = p.subtitle { Text(s).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary) }
                    ProgressBar(fraction: p.progress(), height: 4)
                    if channel.archiveDays > 0, p.start < Date().addingTimeInterval(-60) {
                        Button { onCatchup(p) } label: { Label("Watch from the start", systemImage: "gobackward") }.buttonStyle(.bordered).controlSize(.small)
                    }
                    if let d = p.description { Text(d).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(4) }
                }
            } else {
                Text("Program information unavailable").font(Typography.body).foregroundStyle(ColorTokens.textTertiary)
            }
            if channel.archiveDays > 0, !past.isEmpty {
                Divider().overlay(ColorTokens.border)
                Text("EARLIER · CATCH-UP").font(Typography.micro).tracking(1.2).foregroundStyle(ColorTokens.textSecondary)
                ForEach(past.prefix(12)) { p in
                    Button { onCatchup(p) } label: {
                        HStack(alignment: .firstTextBaseline) {
                            Text(TimeFormatter.time(p.start)).font(Typography.mono).foregroundStyle(ColorTokens.textSecondary).frame(width: 64, alignment: .leading)
                            Text(p.title).font(Typography.body).lineLimit(1)
                            Spacer()
                            Image(systemName: "play.circle").foregroundStyle(ColorTokens.textSecondary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).help("Watch \(p.title) from the provider's archive")
                }
            }
            if !later.isEmpty {
                Divider().overlay(ColorTokens.border)
                ForEach(later) { p in
                    HStack(alignment: .firstTextBaseline) {
                        Text(TimeFormatter.time(p.start)).font(Typography.mono).foregroundStyle(ColorTokens.textSecondary).frame(width: 64, alignment: .leading)
                        Text(p.title).font(Typography.body).lineLimit(1)
                        Spacer()
                        if settings.remindersEnabled { Button { toggleReminder(p) } label: { Image(systemName: reminded.contains(p.id) ? "bell.fill" : "bell") }
                            .buttonStyle(.plain).foregroundStyle(reminded.contains(p.id) ? Color.accentColor : ColorTokens.textSecondary)
                            .help(reminded.contains(p.id) ? "Cancel reminder" : "Remind me when it starts").accessibilityLabel(reminded.contains(p.id) ? "Cancel reminder for \(p.title)" : "Remind me when \(p.title) starts") }
                    }
                }
            }
        }
        .padding(Spacing.lg).frame(maxWidth: .infinity, alignment: .leading).surface()
        .task(id: upcoming.map(\.id)) {
            guard let r = container?.reminders else { return }
            var s = Set<Int64>()
            for p in later where await r.hasReminder(programID: p.id) { s.insert(p.id) }
            reminded = s
        }
    }

    private func toggleReminder(_ p: EPGProgram) {
        guard let r = container?.reminders else { return }
        Task {
            if reminded.contains(p.id) { r.cancel(programID: p.id); reminded.remove(p.id) }
            else if await r.schedule(program: p, channelName: channel.name) { reminded.insert(p.id); state.toasts.show("Reminder set for \(p.title)", symbol: "bell.fill") }
            else { state.toasts.show("Couldn't set a reminder. Allow notifications for StreamSetu in System Settings.", symbol: "bell.slash", kind: .warning) }
        }
    }
}
