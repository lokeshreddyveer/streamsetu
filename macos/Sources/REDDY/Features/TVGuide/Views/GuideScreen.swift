import SwiftUI
import AppKit

/// TV Guide: fixed channel labels on the left, a time grid on the right that moves horizontally.
struct GuideScreen: View {
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @Environment(AppRouter.self) private var router
    @Environment(AppSettings.self) private var settings
    @Environment(\.reddyAccent) private var accent
    @State private var vm = GuideViewModel()
    @State private var scrollMonitor: Any?
    @State private var clock = Date()

    private var scope: GuideScope {
        switch router.selection {
        case .shortcut(.favorites): .favorites
        case .folder(let id): .category(id)
        default: .withGuide
        }
    }
    private var scopeTitle: String {
        switch scope { case .withGuide: "All channels with a guide"; case .favorites: "Favorites"; case .category(let id): state.folderName(id) ?? "Group" }
    }
    private var zoneNote: String {
        let tz = TimeZone.current
        return "Times in \(tz.identifier) (\(tz.abbreviation(for: vm.windowStart) ?? tz.identifier))"
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(ColorTokens.line).frame(height: 1)
            if state.activeSource == nil {
                EmptyStateView(symbol: "list.bullet.rectangle", title: "No playlist", message: "Add a playlist to see its guide.", actionTitle: "Add playlist") { router.modal = .addPlaylist }
            } else if vm.loading { LoadingView(label: "Loading guide…") }
            else if vm.channels.isEmpty { empty }
            else { grid }
        }
        .focusable().focusEffectDisabled()
        .onKeyPress(.leftArrow) { vm.shift(hours: -0.5); return .handled }
        .onKeyPress(.rightArrow) { vm.shift(hours: 0.5); return .handled }
        .task { vm.hours = settings.guideHoursVisible }
        .task(id: "\(state.catalogVersion)-\(String(describing: scope))-\(state.activeSourceID?.uuidString ?? "")") {
            vm.scope = scope; vm.sourceID = state.activeSourceID
            if let c = container { await vm.reload(c) }
        }
        .task { while !Task.isCancelled { try? await Task.sleep(nanoseconds: 30_000_000_000); clock = Date() } }
        .onChange(of: settings.guideHoursVisible) { _, v in vm.hours = v }
        .onAppear { installScrollMonitor() }
        .onDisappear { if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil } }
    }

    // MARK: toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text("TV Guide").font(.system(size: 23, weight: .semibold)).tracking(-0.6).lineLimit(1).accessibilityAddTraits(.isHeader)
                .layoutPriority(-1)                               // the title gives way, so the controls are never pushed off the edge
            Spacer(minLength: 8)
            IconButton(symbol: "chevron.left", help: "Earlier", size: 28) { vm.shift(hours: -vm.hours / 2) }
            Menu {
                ForEach(0..<7, id: \.self) { i in
                    let d = GuideViewModel.evening(daysFromNow: i)
                    Button(i == 0 ? "Today" : i == 1 ? "Tomorrow" : d.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))) { vm.jump(toDay: i) }
                }
            } label: { Label(vm.dayLabel, systemImage: "calendar") }.menuStyle(.button).fixedSize()
            IconButton(symbol: "chevron.right", help: "Later", size: 28) { vm.shift(hours: vm.hours / 2) }
            Button { vm.jumpToNow() } label: { Label("Now", systemImage: "clock") }.fixedSize()
            Picker("Hours visible", selection: Binding(get: { settings.guideHoursVisible }, set: { settings.guideHoursVisible = $0 })) {
                Text("2h").tag(2.0); Text("3h").tag(3.0); Text("4h").tag(4.0); Text("6h").tag(6.0)
            }.pickerStyle(.segmented).frame(width: 140).labelsHidden()
        }
        .padding(.horizontal, LayoutTokens.gutter).padding(.vertical, 10)
    }

    // MARK: grid

    private var grid: some View {
        GeometryReader { g in
            let track = max(300, g.size.width - LayoutTokens.guideChannelWidth)
            VStack(spacing: 0) {
                ruler
                ZStack(alignment: .topLeading) {
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 1) {
                            ForEach(vm.channels) { ch in
                                GuideRow(channel: ch, programs: vm.programs[ch.id], vm: vm, isPlaying: container?.playback.currentChannel?.id == ch.id, onPlay: play)
                                    .task(id: vm.bucket) { if let c = container { await vm.loadRow(ch, c) } }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    nowMarker
                }
            }
            .onAppear { vm.trackWidth = track }
            .onChange(of: track) { _, t in vm.trackWidth = t }
        }
    }

    private var ruler: some View {
        HStack(spacing: 0) {
            Text(vm.windowStart.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))).font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary)
                .frame(width: LayoutTokens.guideChannelWidth, height: 28, alignment: .leading).padding(.leading, 12).background(ColorTokens.panel)
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(ticks, id: \.self) { t in
                    Text(t.formatted(date: .omitted, time: .shortened)).font(Typography.micro).foregroundStyle(ColorTokens.textSecondary).offset(x: vm.x(for: t) + 4, y: 7)
                    Rectangle().fill(ColorTokens.line).frame(width: 1, height: 28).offset(x: vm.x(for: t))
                }
            }.frame(width: vm.trackWidth, height: 28).clipped()
        }
        .background(ColorTokens.background).overlay(alignment: .bottom) { Rectangle().fill(ColorTokens.line).frame(height: 1) }
    }

    private var ticks: [Date] {
        let first = GuideViewModel.snap(vm.windowStart)
        return stride(from: 0.0, through: vm.hours * 3600 + 1800, by: 1800).map { first.addingTimeInterval($0) }.filter { $0 >= vm.windowStart && $0 < vm.windowEnd }
    }

    @ViewBuilder private var nowMarker: some View {
        let x = vm.x(for: clock)
        if x >= 0 && x <= vm.trackWidth {
            VStack(spacing: 0) { Circle().fill(accent).frame(width: 8, height: 8); Rectangle().fill(accent).frame(width: 2) }
                .offset(x: LayoutTokens.guideChannelWidth + x - 4).allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    private var empty: some View {
        let favorites = scope == .favorites
        return EmptyStateView(symbol: "calendar.badge.exclamationmark", title: favorites ? "No favorite channels" : "No programme guide for this view",
                              message: favorites ? "Favorite a few channels to see their schedules here."
                                                 : "Your provider hasn't supplied guide data for these channels, or it is still downloading. You can add a guide (XMLTV) address under Account → Manage playlists.",
                              actionTitle: favorites ? nil : "Manage playlists") { router.modal = .playlists }
    }

    // MARK: actions

    private func play(_ ch: Channel) { container?.playback.play(channel: ch, queue: vm.channels) }

    /// Trackpad / wheel horizontal scrolling moves the time window.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.2 else { return event }
            MainActor.assumeIsolated { vm.scroll(points: event.scrollingDeltaX) }
            return nil
        }
    }
}
