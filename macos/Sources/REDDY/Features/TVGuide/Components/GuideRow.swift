import SwiftUI

struct GuideRow: View {
    let channel: Channel
    let programs: [EPGProgram]?
    let vm: GuideViewModel
    let isPlaying: Bool
    let onPlay: (Channel) -> Void
    @State private var selected: EPGProgram?
    @Environment(\.reddyAccent) private var accent
    @Environment(AppState.self) private var state
    @Environment(\.container) private var container

    var body: some View {
        HStack(spacing: 0) {
            Button { onPlay(channel) } label: {
                HStack(spacing: Spacing.sm) {
                    ChannelLogo(url: channel.logoURL, name: channel.name, size: 36)
                    Text(channel.name).font(Typography.captionMedium).lineLimit(2).multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    if isPlaying { Image(systemName: "waveform").foregroundStyle(accent).font(.caption) }
                }
                .padding(.horizontal, Spacing.md).frame(width: LayoutTokens.guideChannelWidth, height: LayoutTokens.guideRowHeight, alignment: .leading)
                .background(ColorTokens.sidebar)
            }.buttonStyle(.plain).help("Watch \(channel.name)")

            ZStack(alignment: .topLeading) {
                Color.clear
                if let programs {
                    ForEach(visible(programs)) { p in block(p) }
                    if programs.isEmpty { Text("Program information unavailable").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary).padding(.leading, 12).frame(height: LayoutTokens.guideRowHeight) }
                } else { SkeletonBlock(height: LayoutTokens.guideRowHeight - 10, radius: 8).padding(.vertical, 5).padding(.horizontal, 4) }
            }
            .frame(width: vm.trackWidth, height: LayoutTokens.guideRowHeight).clipped()
        }
        .frame(height: LayoutTokens.guideRowHeight)
    }

    private func visible(_ list: [EPGProgram]) -> [EPGProgram] { list.filter { $0.end > vm.windowStart && $0.start < vm.windowEnd } }

    @ViewBuilder private func block(_ p: EPGProgram) -> some View {
        let left = max(0, vm.x(for: p.start)), right = min(vm.trackWidth, vm.x(for: p.end))
        let w = max(2, right - left - 2)
        let live = p.isLive(), past = p.end < Date()
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(live ? accent.opacity(0.22) : ColorTokens.card)
            if live { GeometryReader { g in Rectangle().fill(accent.opacity(0.28)).frame(width: g.size.width * p.progress()) }.clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous)) }
            VStack(alignment: .leading, spacing: 1) {
                Text(p.title).font(Typography.captionMedium).lineLimit(1)
                if w > 90 { Text("\(TimeFormatter.time(p.start)) – \(TimeFormatter.time(p.end))").font(Typography.micro).foregroundStyle(ColorTokens.textSecondary).lineLimit(1) }
            }.padding(.horizontal, 8).opacity(past ? 0.55 : 1)
        }
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(live ? accent.opacity(0.7) : ColorTokens.border))
        .frame(width: w, height: LayoutTokens.guideRowHeight - 8)
        .offset(x: left + 1, y: 4)
        .contentShape(Rectangle())
        .onTapGesture { if live { onPlay(channel) } else { selected = p } }
        .contextMenu { Button("Details") { selected = p }; if live { Button("Watch Now") { onPlay(channel) } } }
        .popover(item: Binding(get: { selected?.id == p.id ? selected : nil }, set: { selected = $0 })) { prog in
            ProgramPopover(program: prog, channel: channel, onWatch: { onPlay(channel) }, onCatchup: { container?.playback.playCatchup(channel: channel, program: prog); selected = nil })
        }
        .help(p.title)
    }
}

struct ProgramPopover: View {
    let program: EPGProgram
    let channel: Channel
    var onWatch: () -> Void
    var onCatchup: () -> Void = {}
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @Environment(AppSettings.self) private var settings
    @State private var hasReminder = false
    @State private var recording = false
    @State private var recordsWeekly = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text(program.title).font(Typography.heading)
            if let s = program.subtitle { Text(s).font(Typography.body).foregroundStyle(ColorTokens.textSecondary) }
            Text("\(channel.name) · \(TimeFormatter.dayAndTime(program.start)) – \(TimeFormatter.time(program.end))").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
            if let c = program.category { QualityBadge(text: c) }
            if let d = program.description { Text(d).font(Typography.body).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 340, alignment: .leading) }
            HStack {
                if program.isLive() { PrimaryButton(title: "Watch Now", symbol: "play.fill", action: onWatch) }
                if channel.archiveDays > 0, program.start < Date(), program.start > Date().addingTimeInterval(-TimeInterval(min(channel.archiveDays, 7)) * 86400) {
                    SecondaryButton(title: program.isLive() ? "Watch from the start" : "Watch (catch-up)", symbol: "gobackward", action: onCatchup)
                }
                if program.start > Date() && settings.remindersEnabled {
                    SecondaryButton(title: hasReminder ? "Cancel Reminder" : "Remind Me", symbol: hasReminder ? "bell.slash" : "bell") { toggle() }
                }
                if program.end > Date(), let rec = container?.scheduledRecordings {
                    SecondaryButton(title: recording ? (recordsWeekly ? "Cancel Every Week" : "Cancel Recording") : "Record", symbol: recording ? "stop.circle" : "record.circle") {
                        if recording { rec.cancel(channelID: channel.id, start: program.start); recording = false; recordsWeekly = false }
                        else if rec.schedule(program: program, channel: channel) { recording = true; state.toasts.show("Will record \(program.title)", symbol: "record.circle", kind: .info) }
                    }
                    if !recording {
                        SecondaryButton(title: "Record Every Week", symbol: "repeat") {
                            if rec.schedule(program: program, channel: channel, weekly: true) { recording = true; recordsWeekly = true; state.toasts.show("Will record \(program.title) every week", symbol: "repeat", kind: .info) }
                        }
                    }
                }
            }
        }
        .padding(Spacing.lg).frame(width: 380, alignment: .leading)
        .task { hasReminder = await container?.reminders.hasReminder(programID: program.id) ?? false; recording = container?.scheduledRecordings.isScheduled(channelID: channel.id, start: program.start) ?? false; recordsWeekly = container?.scheduledRecordings.repeatsWeekly(channelID: channel.id, start: program.start) ?? false }
    }

    private func toggle() {
        guard let r = container?.reminders else { return }
        Task {
            if hasReminder { r.cancel(programID: program.id); hasReminder = false }
            else if await r.schedule(program: program, channelName: channel.name) { hasReminder = true; state.toasts.show("Reminder set for \(program.title)", symbol: "bell.fill") }
            else { state.toasts.show("Couldn't set a reminder. Allow notifications for StreamSetu in System Settings.", symbol: "bell.slash", kind: .warning) }
        }
    }
}
