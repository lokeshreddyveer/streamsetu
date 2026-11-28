import SwiftUI
#if os(macOS)
import AppKit
import Carbon.HIToolbox
#endif

/// Settings, Automation: schedules and alarms, rules for audio outputs, what happens when Music opens, triggers, keyboard shortcuts, the local control door and what each of them may do.
/// Everything here runs only while StreamSetu is open, and each way in has its own permissions.
struct MusicAutomationSheet: View {
    enum Tab: Hashable { case schedules, rules, triggers, keys, local, permissions }
    let hub: MusicHub
    let close: () -> Void
    @State private var tab: Tab = .schedules
    @State private var scheduler = MusicScheduler.shared
    @State private var api = MusicLocalAPI.shared
    #if os(macOS)
    @State private var keys = MusicHotkeys.shared
    #endif
    @State private var apiOn = MusicLocalAPI.shared.isEnabled
    @State private var showToken = false
    @State private var perms: [MusicAutomationSource: Set<MusicAutomationScope>] = Dictionary(uniqueKeysWithValues: MusicAutomationSource.allCases.map { ($0, MusicAutomationPermissions.scopes($0)) })
    @Environment(\.reddyAccent) private var accent

    private var commands: [MusicCommandName] { MusicCommandName.allCases.filter { $0 != .nowPlaying } }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.md) {
            HStack {
                Text(Localized.string("Automation")).font(MusicTokens.sheetTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.musicButton(.glassIcon, size: .regular)
                    .accessibilityLabel(Localized.string("Close")).keyboardShortcut(.cancelAction).atlas("control.music.automationClose")
            }
            Picker("", selection: $tab) {
                Text(Localized.string("Schedules")).tag(Tab.schedules)
                Text(Localized.string("Outputs and start")).tag(Tab.rules)
                Text(Localized.string("Triggers")).tag(Tab.triggers)
                Text(Localized.string("Shortcuts")).tag(Tab.keys)
                Text(Localized.string("Local control")).tag(Tab.local)
                Text(Localized.string("Permissions")).tag(Tab.permissions)
            }.pickerStyle(.segmented).labelsHidden().atlas("control.music.automationTab")
            Text(Localized.string("These run only while StreamSetu is open. Nothing is installed that runs on its own in the background.")).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
            ScrollView {
                VStack(alignment: .leading, spacing: MusicSpace.md) {
                    switch tab {
                    case .schedules: schedules
                    case .rules: rules
                    case .triggers: triggers
                    case .keys: keyList
                    case .local: local
                    case .permissions: permissions
                    }
                }
            }
        }
        .padding(MusicSpace.lg)
        .frame(minWidth: 640, idealWidth: 700, minHeight: 560)
    }

    // MARK: command picker

    private func commandPicker(_ call: Binding<MusicCommandCall>, id: String) -> some View {
        HStack(spacing: MusicSpace.xs) {
            Picker("", selection: Binding(get: { call.wrappedValue.name }, set: { call.wrappedValue.name = $0 })) {
                ForEach(commands, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }.labelsHidden().fixedSize().atlas("control.music.automationCommand")
            if call.wrappedValue.command?.takesArgument == true {
                TextField(argHint(call.wrappedValue.command), text: Binding(get: { call.wrappedValue.argument ?? "" }, set: { call.wrappedValue.argument = $0 })).textFieldStyle(.roundedBorder).frame(width: 150).atlas("control.music.automationArgument")
            }
        }
    }

    private func argHint(_ c: MusicCommandName?) -> String {
        switch c { case .setVolume: "0–100"; case .sleepTimer: Localized.string("minutes"); case .listeningMode: "study, album, party…"; default: Localized.string("playlist name") }
    }

    // MARK: schedules

    private var schedules: some View {
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            HStack {
                Button { scheduler.config.schedules.append(MusicSchedule(kind: .play, hour: 8, minute: 0)) } label: { Label(Localized.string("Start music at a time"), systemImage: "play.circle") }.musicButton(.secondary, size: .compact).atlas("control.music.automationAddPlay")
                Button { scheduler.config.schedules.append(MusicSchedule(kind: .alarm, hour: 7, minute: 0)) } label: { Label(Localized.string("Wake-up alarm"), systemImage: "alarm") }.musicButton(.secondary, size: .compact).atlas("control.music.automationAddAlarm")
                Button { scheduler.config.schedules.append(MusicSchedule(kind: .stop, hour: 23, minute: 0)) } label: { Label(Localized.string("Stop at a time"), systemImage: "moon.zzz") }.musicButton(.secondary, size: .compact).atlas("control.music.automationAddStop")
            }
            if scheduler.config.schedules.isEmpty { Text(Localized.string("No schedules yet.")).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary) }
            ForEach($scheduler.config.schedules) { $s in
                MusicSheetCard {
                    VStack(alignment: .leading, spacing: MusicSpace.xs) {
                        HStack {
                            Toggle("", isOn: $s.enabled).labelsHidden().toggleStyle(.switch).atlas("control.music.automationEnabled")
                            Text(verbatim: s.kind == .play ? Localized.string("Play") : (s.kind == .alarm ? Localized.string("Alarm") : Localized.string("Stop"))).font(Typography.bodyMedium)
                            DatePicker("", selection: Binding(get: { Calendar.current.date(from: DateComponents(hour: s.hour, minute: s.minute)) ?? Date() },
                                                              set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); s.hour = c.hour ?? 0; s.minute = c.minute ?? 0 }), displayedComponents: .hourAndMinute)
                                .labelsHidden().atlas("control.music.automationTime")
                            Spacer()
                            Button { scheduler.config.schedules.removeAll { $0.id == s.id } } label: { Image(systemName: "trash") }.buttonStyle(.plain).accessibilityLabel(Localized.string("Delete")).atlas("control.music.automationDelete")
                        }
                        HStack(spacing: 4) {
                            ForEach(Array(Calendar.current.veryShortWeekdaySymbols.enumerated()), id: \.offset) { i, sym in
                                let day = i + 1, on = s.weekdays.isEmpty || s.weekdays.contains(day)
                                Button { if s.weekdays.isEmpty { s.weekdays = Set(1...7).subtracting([day]) } else if s.weekdays.contains(day) { s.weekdays.remove(day) } else { s.weekdays.insert(day) }; if s.weekdays.count == 7 { s.weekdays = [] } } label: {
                                    Text(verbatim: sym).font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24).background(Circle().fill(on ? accent.opacity(0.25) : ColorTokens.surface))
                                }.buttonStyle(.plain).atlas("control.music.automationDay")
                            }
                        }
                        if s.kind != .stop { commandPicker($s.call, id: s.id.uuidString) }
                        if s.kind == .alarm {
                            Stepper(Localized.string("Fade in over %@ seconds", String(s.fadeSeconds)), value: $s.fadeSeconds, in: 10...600, step: 10).font(Typography.caption).atlas("control.music.automationFade")
                        }
                    }
                }
            }
        }
    }

    // MARK: rules and launch

    private var rules: some View {
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            MusicSheetCard {
                VStack(alignment: .leading, spacing: MusicSpace.xs) {
                    Toggle(Localized.string("Do something when Music opens"), isOn: Binding(get: { scheduler.config.launch != nil }, set: { scheduler.config.launch = $0 ? MusicCommandCall(name: MusicCommandName.playLikedShuffled.rawValue) : nil })).toggleStyle(.switch).atlas("control.music.automationLaunchOn")
                    if scheduler.config.launch != nil { commandPicker(Binding(get: { scheduler.config.launch ?? MusicCommandCall(name: "play") }, set: { scheduler.config.launch = $0 }), id: "launch") }
                }
            }
            HStack {
                Text(Localized.string("When an audio output connects")).font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary)
                Spacer()
                Button { scheduler.config.rules.append(MusicOutputRule(match: "", calls: [MusicCommandCall(name: "play")])) } label: { Label(Localized.string("Add a rule"), systemImage: "plus") }.musicButton(.secondary, size: .compact).atlas("control.music.automationAddRule")
            }
            if hub.player.outputs.available.isEmpty == false {
                Text(Localized.string("Outputs now: %@", hub.player.outputs.available.map(\.name).joined(separator: ", "))).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
            }
            ForEach($scheduler.config.rules) { $r in
                MusicSheetCard {
                    VStack(alignment: .leading, spacing: MusicSpace.xs) {
                        HStack {
                            Toggle("", isOn: $r.enabled).labelsHidden().toggleStyle(.switch).atlas("control.music.automationRuleEnabled")
                            TextField(Localized.string("Part of the output's name, such as AirPods"), text: $r.match).textFieldStyle(.roundedBorder).atlas("control.music.automationRuleMatch")
                            Button { scheduler.config.rules.removeAll { $0.id == r.id } } label: { Image(systemName: "trash") }.buttonStyle(.plain).accessibilityLabel(Localized.string("Delete")).atlas("control.music.automationRuleDelete")
                        }
                        commandPicker(Binding(get: { r.calls.first ?? MusicCommandCall(name: "play") }, set: { r.calls = [$0] }), id: r.id.uuidString)
                    }
                }
            }
        }
    }

    // MARK: triggers

    private var triggers: some View {
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            Button { scheduler.config.triggers.append(MusicTrigger(event: .playbackPaused, call: MusicCommandCall(name: "like"))) } label: { Label(Localized.string("Add a trigger"), systemImage: "plus") }
                .musicButton(.secondary, size: .compact).atlas("control.music.automationAddTrigger")
            ForEach($scheduler.config.triggers) { $t in
                MusicSheetCard {
                    HStack {
                        Toggle("", isOn: $t.enabled).labelsHidden().toggleStyle(.switch).atlas("control.music.automationTriggerEnabled")
                        Text(Localized.string("When")).font(Typography.caption)
                        Picker("", selection: $t.event) { ForEach(MusicTrigger.Event.allCases, id: \.self) { Text($0.title).tag($0) } }.labelsHidden().fixedSize().atlas("control.music.automationEvent")
                        Text(Localized.string("do")).font(Typography.caption)
                        commandPicker($t.call, id: t.id.uuidString)
                        Spacer()
                        Button { scheduler.config.triggers.removeAll { $0.id == t.id } } label: { Image(systemName: "trash") }.buttonStyle(.plain).accessibilityLabel(Localized.string("Delete")).atlas("control.music.automationTriggerDelete")
                    }
                }
            }
        }
    }

    // MARK: keys

    #if os(macOS)
    private var keyList: some View {
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            Text(Localized.string("Choose a key combination for a command. A global shortcut works from any app; otherwise it works only while StreamSetu is in front. Use at least one of Control, Option or Command.")).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
            Button { keys.bindings.append(MusicAutomationKey(call: MusicCommandCall(name: "playPause"), combo: MusicKeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey)))) } label: { Label(Localized.string("Add a shortcut"), systemImage: "plus") }
                .musicButton(.secondary, size: .compact).atlas("control.music.automationAddKey")
            ForEach($keys.bindings) { $b in
                MusicSheetCard {
                    HStack {
                        commandPicker($b.call, id: b.id.uuidString)
                        MusicKeyRecorder(combo: $b.combo)
                        Toggle(Localized.string("Global"), isOn: $b.global).toggleStyle(.switch).atlas("control.music.automationGlobal")
                        Spacer()
                        Button { keys.bindings.removeAll { $0.id == b.id } } label: { Image(systemName: "trash") }.buttonStyle(.plain).accessibilityLabel(Localized.string("Delete")).atlas("control.music.automationKeyDelete")
                    }
                    if keys.conflicts(b.combo, except: b.id) { Text(Localized.string("Another shortcut already uses these keys.")).font(Typography.caption).foregroundStyle(.orange) }
                }
            }
        }
    }
    #else
    private var keyList: some View { Text(Localized.string("Keyboard shortcuts are for the Mac app.")).font(Typography.caption) }
    #endif

    // MARK: local control

    private var local: some View {
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            MusicSheetCard {
                VStack(alignment: .leading, spacing: MusicSpace.xs) {
                    Toggle(Localized.string("Allow trusted programs on this Mac to control Music"), isOn: Binding(get: { apiOn }, set: { apiOn = $0; api.setEnabled($0, hub: hub) })).toggleStyle(.switch).atlas("control.music.automationAPIOn")
                    Text(Localized.string("It listens only on this Mac, every request needs the secret token below, and it can do only what you allow under Permissions (nothing, until you choose).")).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                    if apiOn {
                        Text(api.running ? Localized.string("Running on port %@.", String(api.port)) : (api.lastError ?? Localized.string("Starting…"))).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
                        HStack {
                            Text(verbatim: showToken ? api.token : String(repeating: "•", count: 24)).font(Typography.timestamp).textSelection(.enabled)
                            Button(showToken ? Localized.string("Hide") : Localized.string("Show token")) { showToken.toggle() }.buttonStyle(.plain).foregroundStyle(accent).atlas("control.music.automationShowToken")
                            #if os(macOS)
                            Button(Localized.string("Copy")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(api.token, forType: .string) }.buttonStyle(.plain).foregroundStyle(accent).atlas("control.music.automationCopyToken")
                            #endif
                            Button(Localized.string("Make a new token")) { api.resetToken(); showToken = false }.buttonStyle(.plain).foregroundStyle(accent).atlas("control.music.automationResetToken")
                        }
                        Text(Localized.string("Command line: Scripts/streamsetu-ctl (put the token in ~/.config/streamsetu/token).")).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
                    }
                }
            }
        }
    }

    // MARK: permissions

    private var permissions: some View {
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            Text(Localized.string("What each way in may do. Anything you do yourself (the palette, your own keys, schedules you set) is allowed; links and local control start with very little.")).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
            ForEach(MusicAutomationSource.allCases, id: \.self) { src in
                MusicSheetCard {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: src.title).font(Typography.bodyMedium)
                        ForEach(MusicAutomationScope.allCases, id: \.self) { sc in
                            Toggle(sc.title, isOn: Binding(get: { perms[src]?.contains(sc) ?? false }, set: { on in
                                var s = perms[src] ?? []; if on { s.insert(sc) } else { s.remove(sc) }
                                perms[src] = s; MusicAutomationPermissions.set(s, for: src)
                            })).toggleStyle(.switch).font(Typography.caption).atlas("control.music.automationPermission")
                        }
                    }
                }
            }
        }
    }
}

#if os(macOS)
/// Click, then press the keys: the combination is captured. Escape cancels.
struct MusicKeyRecorder: View {
    @Binding var combo: MusicKeyCombo
    @State private var recording = false
    @State private var monitor: Any?
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        Button { toggle() } label: {
            Text(verbatim: recording ? Localized.string("Press the keys…") : combo.display).font(Typography.timestamp)
                .padding(.horizontal, 10).padding(.vertical, 5).background(RoundedRectangle(cornerRadius: 6).fill(recording ? accent.opacity(0.25) : ColorTokens.surface))
        }.buttonStyle(.plain).accessibilityLabel(Localized.string("Change the keys")).atlas("control.music.automationRecordKey")
        .onDisappear { stop() }
    }

    private func toggle() {
        if recording { stop(); return }
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            let m = MusicKeyCombo.carbon(from: e.modifierFlags)
            guard m & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
            combo = MusicKeyCombo(keyCode: UInt32(e.keyCode), modifiers: m)
            stop()
            return nil
        }
    }

    private func stop() { recording = false; if let m = monitor { NSEvent.removeMonitor(m); monitor = nil } }
}
#endif
