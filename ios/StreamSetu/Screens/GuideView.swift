import SwiftUI

/// The TV guide: channels down the side, time across. Drag sideways to move through time.
struct GuideView: View {
    var embedded = false
    @Environment(AppState.self) private var state
    @Environment(IOSRouter.self) private var router
    @Environment(\.container) private var container
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var vm = GuideViewModel()
    @State private var selected: Selection?
    @State private var lastDrag: CGFloat = 0
    @State private var categories: [CatalogCategory] = []
    @State private var tick = Date()
    @Environment(\.tabActive) private var tabActive
    @Environment(\.scenePhase) private var scenePhase

    private let nameWidth: CGFloat = 92
    private let rowHeight: CGFloat = 58

    struct Selection: Identifiable { let channel: Channel; let program: EPGProgram; var id: Int64 { program.id } }

    var body: some View {
        OptionalStack(embedded: embedded) {
            GeometryReader { geo in
                let track = max(120, geo.size.width - nameWidth)
                VStack(spacing: 0) {
                    ruler(track: track)
                    Divider()
                    if vm.channels.isEmpty, !vm.loading {
                        EmptyState(symbol: "calendar", title: "No guide data", message: state.isSyncing ? "The guide appears when the playlist has been read." : "This playlist has no programme guide, or no channel is matched to it. A guide address can be set in the playlist's settings.").frame(maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(vm.channels) { c in
                                    row(c, track: track)
                                    Divider().overlay(ColorTokens.line)
                                }
                            }
                        }
                        .overlay(alignment: .topLeading) { nowMarker(track: track) }
                    }
                }
                .onAppear { vm.trackWidth = track; vm.hours = sizeClass == .regular ? 4 : 3 }
                .onChange(of: geo.size.width) { _, _ in vm.trackWidth = track }
                .simultaneousGesture(DragGesture(minimumDistance: 14).onChanged { v in
                    guard abs(v.translation.width) > abs(v.translation.height) else { return }
                    vm.scroll(points: v.translation.width - lastDrag); lastDrag = v.translation.width
                }.onEnded { _ in lastDrag = 0 })
            }
            .navigationTitle("Guide").themed("Guide · \(vm.dayLabel)").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                TrailingPills {
                    Menu {
                        Button("Now") { vm.jumpToNow() }
                        Button("Tonight") { vm.jump(toDay: 0); vm.windowStart = GuideViewModel.evening(daysFromNow: 0) }
                        Button("Tomorrow evening") { vm.jump(toDay: 1) }
                        Divider()
                        Button("Earlier (−3 h)") { vm.shift(hours: -3) }
                        Button("Later (+3 h)") { vm.shift(hours: 3) }
                    } label: { Image(systemName: "clock").pillIcon() }.accessibilityLabel("Jump in time")
                    Menu {
                        Button { setScope(.withGuide) } label: { Label("Channels with a guide", systemImage: vm.scope == .withGuide ? "checkmark" : "") }
                        Button { setScope(.favorites) } label: { Label("Favourites", systemImage: vm.scope == .favorites ? "checkmark" : "") }
                        Divider()
                        ForEach(categories) { cat in Button { setScope(.category(cat.id)) } label: { Label(cat.name, systemImage: vm.scope == .category(cat.id) ? "checkmark" : "") } }
                    } label: { Image(systemName: "line.3.horizontal.decrease.circle").pillIcon() }.accessibilityLabel("Which channels")
                }
            }
            .sheet(item: $selected) { ProgrammeSheet(selection: $0) }
            .miniPlayerInset()
        }
        .task(id: "\(state.activeSourceID?.uuidString ?? "")-\(state.catalogVersion)") {
            guard let c = container else { return }
            vm.sourceID = state.activeSourceID
            await vm.reload(c)
            let sid = state.activeSourceID
            categories = await Task.detached { (try? c.catalog.categories(sourceID: sid, kind: .channel, includeHidden: false)) ?? [] }.value
        }
        // The minute hand: a task, so it stops when this screen is not showing and starts again when it is.
        // Only while this screen is the one on show and the app is in front; the marker is brought up to date the moment it comes back.
        .task(id: "\(tabActive)-\(scenePhase == .active)") {
            guard tabActive, scenePhase == .active else { return }
            tick = Date()
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 60_000_000_000); if !Task.isCancelled { tick = Date() } }
        }
    }

    private func setScope(_ s: GuideScope) {
        vm.scope = s
        if let c = container { Task { await vm.reload(c) } }
    }

    // MARK: pieces

    private func ruler(track: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(height: 26)
            ForEach(ticks, id: \.self) { t in
                let x = nameWidth + vm.x(for: t)
                if x >= nameWidth, x < nameWidth + track - 30 {
                    Text(t.formatted(date: .omitted, time: .shortened)).appFont(11).foregroundStyle(.secondary).offset(x: x + 4, y: 5)
                    Rectangle().fill(ColorTokens.line).frame(width: 1, height: 26).offset(x: x)
                }
            }
        }
    }

    private var ticks: [Date] {
        let start = GuideViewModel.snap(vm.windowStart)
        return stride(from: 0.0, through: vm.hours * 2 + 2, by: 1).map { start.addingTimeInterval($0 * 1800) }.filter { $0 >= vm.windowStart }
    }

    private func nowMarker(track: CGFloat) -> some View {
        let x = vm.x(for: tick)
        return Group {
            if x > 0, x < track { Rectangle().fill(.red.opacity(0.85)).frame(width: 2).offset(x: nameWidth + x).allowsHitTesting(false) }
        }
    }

    private func row(_ c: Channel, track: CGFloat) -> some View {
        HStack(spacing: 0) {
            Button { if let container { Play.channel(c, queue: vm.channels, container) } } label: {
                VStack(spacing: 3) {
                    ChannelLogo(url: c.logoURL, name: c.name, size: 30)
                    Text(c.name).appFont(10).lineLimit(1).foregroundStyle(.secondary)
                }.frame(width: nameWidth, height: rowHeight)
            }.buttonStyle(.press)
            ZStack(alignment: .topLeading) {
                ForEach(vm.programs[c.id] ?? []) { p in
                    let x0 = max(0, vm.x(for: p.start)), x1 = min(track, vm.x(for: p.end))
                    if x1 - x0 > 3 {
                        Button { selected = Selection(channel: c, program: p) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.title).appFont(12, .medium).lineLimit(2)
                                if x1 - x0 > 90 { Text(p.start.formatted(date: .omitted, time: .shortened)).appFont(10).foregroundStyle(.secondary) }
                            }
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .frame(width: x1 - x0 - 2, height: rowHeight - 6, alignment: .topLeading)
                            .background(p.isLive() ? ColorTokens.accentDefault.opacity(0.28) : ColorTokens.card, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .opacity(p.end < Date() ? 0.6 : 1)
                        }.buttonStyle(.press).offset(x: x0, y: 3)
                    }
                }
            }
            .frame(width: track, height: rowHeight, alignment: .topLeading).clipped()
        }
        .task(id: "\(c.id)-\(vm.bucket)") { if let container { await vm.loadRow(c, container) } }
    }
}

/// What a programme is, and what can be done with it.
private struct ProgrammeSheet: View {
    let selection: GuideView.Selection
    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var reminder = false
    @State private var note: String?

    private var p: EPGProgram { selection.program }
    private var c: Channel { selection.channel }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(p.title).font(.title3.weight(.semibold))
                        Text("\(c.name) · \(p.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())) – \(p.end.formatted(date: .omitted, time: .shortened))").font(.subheadline).foregroundStyle(.secondary)
                        if let d = p.description, !d.isEmpty { Text(d).font(.callout).padding(.top, 4) }
                    }
                }.listRowBackground(ColorTokens.surface)
                Section {
                    if p.isLive() {
                        Button { play() } label: { Label("Watch Now", systemImage: "play.fill") }
                    } else if p.end < Date() {
                        if c.archiveDays > 0 { Button { catchUp() } label: { Label("Watch from the Archive", systemImage: "clock.arrow.circlepath") } }
                        else { Text("This channel has no archive.").foregroundStyle(.secondary) }
                    } else {
                        Button { toggleReminder() } label: { Label(reminder ? "Cancel Reminder" : "Remind Me", systemImage: reminder ? "bell.slash" : "bell") }
                    }
                    if let note { Text(note).font(.callout).foregroundStyle(.secondary) }
                }.listRowBackground(ColorTokens.surface)
            }
            .navigationTitle("Programme").themed("Programme").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
        .task { reminder = await container?.reminders.hasReminder(programID: p.id) ?? false }
    }

    private func play() { guard let container else { return }; dismiss(); Play.channel(c, queue: [c], container) }

    private func catchUp() {
        guard let container else { return }
        dismiss()
        container.playback.playCatchup(channel: c, program: p)
        container.playback.isExpanded = true
    }

    private func toggleReminder() {
        guard let r = container?.reminders else { return }
        Task {
            if reminder { r.cancel(programID: p.id); reminder = false; note = "Reminder cancelled." }
            else if await r.schedule(program: p, channelName: c.name) { reminder = true; note = "You will be reminded a minute before it starts." }
            else { note = "A reminder could not be set. Check that notifications are allowed for StreamSetu in Settings." }
        }
    }
}
