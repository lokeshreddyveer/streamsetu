import SwiftUI

/// "Your week": the digest as a card, with the switch for the Sunday notification.
struct WeeklyDigestCard: View {
    let container: AppContainer
    @State private var digest = WeeklyDigest()
    @State private var loaded = false
    @State private var notify = false
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Your week", systemImage: "calendar").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Text(digest.headline).font(.title3.weight(.bold))
            if loaded, digest.lines.isEmpty { Text("Watch something and your week fills in here.").font(.callout).foregroundStyle(.secondary) }
            ForEach(digest.lines, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
            Toggle("Send me this on Sunday evening", isOn: Binding(get: { notify }, set: { change($0) })).font(.callout).padding(.top, 4)
            if let note { Text(note).font(.caption).foregroundStyle(.orange) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(ColorTokens.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.easeInOut(duration: 0.25), value: digest)
        .task {
            notify = WeeklyDigestSchedule.isEnabled(container.settings.defaultsStore)
            digest = container.weeklyDigest(); loaded = true
        }
    }

    private func change(_ on: Bool) {
        note = nil
        Task {
            if on {
                let status = await NotificationPermission.request()
                guard status == .authorized else {
                    note = status == .denied ? "Notifications are turned off for StreamSetu in System Settings." : "Notifications are not available here."
                    return
                }
            }
            container.settings.defaultsStore.set(on, forKey: WeeklyDigestSchedule.enabledKey)
            notify = on
            container.refreshWeeklyDigest()
        }
    }
}

/// What StreamSetu keeps on this device and what it can send out, as it is now.
struct PrivacyReportView: View {
    let container: AppContainer
    @State private var report = PrivacyReport()
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Kept on this device only", report.stored, showStatus: false)
            section("Can leave this device", report.sentOut)
            VStack(alignment: .leading, spacing: 4) {
                Text("Never").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(PrivacyReport.neverDone, id: \.self) { Label($0, systemImage: "checkmark").font(.callout) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(loaded ? 1 : 0.3)
        .animation(.easeInOut(duration: 0.25), value: loaded)
        .task { report = PrivacyReport.make(container.privacyState()); loaded = true }
    }

    @ViewBuilder private func section(_ title: String, _ items: [PrivacyReport.Item], showStatus: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(showStatus ? color(item.status) : Color.blue.opacity(0.6)).frame(width: 8, height: 8).padding(.top, 6)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack { Text(item.title).font(.body.weight(.medium)); Spacer(); if showStatus { Text(label(item.status)).font(.caption).foregroundStyle(.secondary) } }
                        Text(item.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func color(_ s: PrivacyReport.Status) -> Color { switch s { case .on: .green; case .off: .gray; case .whenYouAsk: .orange } }
    private func label(_ s: PrivacyReport.Status) -> String { switch s { case .on: "On"; case .off: "Off"; case .whenYouAsk: "Only when you ask" } }
}

/// The privacy report as its own screen (iPhone and iPad).
struct PrivacyReportScreen: View {
    @Environment(\.container) private var container
    var body: some View {
        ScrollView {
            if let container { PrivacyReportView(container: container).padding(16) }
        }
        .background(ColorTokens.background)
        .navigationTitle("Privacy Report")
    }
}

/// "Your usual time": what you often put on around this time of day, with a switch for a reminder shortly before.
struct UsualEveningRow: View {
    let container: AppContainer
    @State private var usual: (pick: UsualPick, title: String, play: @MainActor () -> Void)?
    @State private var remind = false
    @State private var note: String?

    var body: some View {
        Group { content }.task {
            remind = container.settings.defaultsStore.bool(forKey: UsualEvening.enabledKey)
            withAnimation(.easeInOut(duration: 0.25)) { usual = container.usualEvening() }
        }
    }

    @ViewBuilder private var content: some View {
        if let usual {
            VStack(alignment: .leading, spacing: 8) {
                Label("Your usual time", systemImage: "clock.arrow.circlepath").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Button { usual.play() } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(usual.title).font(.body.weight(.semibold)).lineLimit(1)
                            Text("You often start around \(UsualEvening.hourText(usual.pick.hour))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "play.fill")
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                Toggle("Remind me ten minutes before", isOn: Binding(get: { remind }, set: { change($0) })).font(.callout)
                if let note { Text(note).font(.caption).foregroundStyle(.orange) }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(ColorTokens.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .transition(.opacity)
        }
    }

    private func change(_ on: Bool) {
        note = nil
        Task {
            if on {
                let status = await NotificationPermission.request()
                guard status == .authorized else { note = status == .denied ? "Notifications are turned off for StreamSetu in System Settings." : "Notifications are not available here."; return }
            }
            container.settings.defaultsStore.set(on, forKey: UsualEvening.enabledKey)
            remind = on
            container.refreshUsualEvening()
        }
    }
}

/// At the top of Home when there is no connection: says so, and offers what plays without one, the saved downloads.
struct OfflineHomeBanner: View {
    let container: AppContainer

    var body: some View {
        Group {
            if !container.connectivity.online {
                VStack(alignment: .leading, spacing: 10) {
                    Label("You're offline", systemImage: "wifi.slash").font(.subheadline.weight(.semibold))
                    if container.downloads.records.contains(where: { $0.state == .done }) {
                        Text("These are saved on this device and play without a connection.").font(.caption).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 8) { DownloadsList() }
                    } else {
                        Text("Nothing is saved for offline viewing yet. Choose Download on a movie or an episode while you are online.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(ColorTokens.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: container.connectivity.online)
    }
}

/// On Home: what your other devices are playing right now, with a button to carry on here.
struct NowPlayingStrip: View {
    let container: AppContainer

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let entries = container.nowBoard.current(now: ctx.date)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(entries) { e in
                    HStack(spacing: 12) {
                        Image(systemName: "tv.and.mediabox").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.title).font(.body.weight(.medium)).lineLimit(1)
                            Text("Playing on \(e.deviceName)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Button("Play here") { container.takeOver(e) }.buttonStyle(.bordered).controlSize(.small)
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(ColorTokens.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: entries)
        }
    }
}
