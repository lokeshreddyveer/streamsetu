import SwiftUI

struct GeneralSettingsPage: View {
    @Environment(AppSettings.self) private var settings
    @State private var notification: NotificationStatus = .unavailable

    var body: some View {
        @Bindable var s = settings
        SettingsPage {
            SettingsGroup(title: "Browsing") {
                SettingsRow(title: "Open channels with", detail: s.clickBehavior == .singleClick ? "One click on a channel starts it." : "Double-click starts a channel; a single click only selects it. Return also plays.") {
                    Picker("Open channels with", selection: $s.clickBehavior) { ForEach(ClickBehavior.allCases) { Text($0.title).tag($0) } }.pickerStyle(.menu).fixedSize()
                }
                SettingsRow(title: "Group quality variants", detail: "Shows HD, FHD and 4K copies of a channel as one entry with a Streams menu.") { Toggle("Group quality variants", isOn: $s.collapseDuplicates) }
                SettingsRow(title: "Hide empty folders", detail: "Folders the provider lists but that currently hold nothing. They are never deleted.") { Toggle("Hide empty folders", isOn: $s.hideEmptyFolders) }
                SettingsRow(title: "Movies and series order", detail: "How Movies and Series are sorted when you open them.") {
                    Picker("Movies and series order", selection: $s.defaultLibrarySort) { ForEach(LibrarySortPreference.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu).fixedSize()
                }
                SettingsRow(title: "Channel order", detail: "Provider order follows the playlist; alphabetical sorts by name.") {
                    Picker("Channel order", selection: $s.defaultChannelSort) { ForEach(ChannelSortPreference.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu).fixedSize()
                }
                SettingsRow(title: "Remember last folder", detail: "Return to the folder you were in when you come back to a tab.", divider: false) { Toggle("Remember last folder", isOn: $s.rememberFolders) }
            }

            SettingsGroup(title: "At launch", footer: "StreamSetu always opens on Home → Discover. This only adds playback on top of that.") {
                SettingsRow(title: "Resume the last channel", detail: "Starts the live channel that was playing when you last quit, in the bottom player.", divider: false) {
                    Toggle("Resume the last channel", isOn: $s.resumeLastChannel)
                }
            }

            SettingsGroup(title: "Notifications", footer: notificationFooter) {
                SettingsRow(title: "Programme reminders", detail: "Adds a bell to upcoming programmes. Reminders are local notifications; nothing leaves this Mac.") {
                    Toggle("Programme reminders", isOn: $s.remindersEnabled)
                }
                SettingsRow(title: "macOS permission", detail: notification.title, divider: false) {
                    switch notification {
                    case .denied: Button("Open Notification Settings") { NotificationPermission.openSystemSettings() }
                    case .notDetermined: AsyncActionButton(title: "Allow Notifications") { notification = await NotificationPermission.request() }
                    case .authorized: HStack(spacing: 6) { StatusDot(color: ColorTokens.success); Text("Authorized").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary) }
                    case .unavailable: Text("—").foregroundStyle(ColorTokens.textTertiary)
                    }
                }
            }
        }
        .task { notification = await NotificationPermission.current() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { notification = await NotificationPermission.current() } }
    }

    private var notificationFooter: String {
        switch notification {
        case .denied: "macOS has denied notifications for StreamSetu, so reminders can't be delivered even with the switch on. Allow them in System Settings → Notifications."
        case .notDetermined: "macOS will ask the first time you set a reminder, or you can allow it here."
        default: "Reminders fire a minute before a programme starts."
        }
    }
}

/// Every accent as a swatch. The selected one carries a ring and a checkmark, so it doesn't rely on colour alone.
struct AccentPicker: View {
    @Binding var selection: AccentChoice
    private let columns = [GridItem(.adaptive(minimum: 34, maximum: 34), spacing: 8, alignment: .leading)]
    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(AccentChoice.allCases) { a in
                Button { withAnimation(AnimationTokens.quick) { selection = a } } label: {
                    ZStack {
                        Circle().fill(a.color).frame(width: 22, height: 22)
                        if a == .coral { Image(systemName: "paintpalette.fill").font(.system(size: 9)).foregroundStyle(.white.opacity(0.9)) }
                        if selection == a { Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white).shadow(radius: 1) }
                    }
                    .padding(3).overlay(Circle().strokeBorder(selection == a ? a.color : .clear, lineWidth: 1.5))
                    .contentShape(Circle())
                }
                .buttonStyle(.plain).help(a.title).accessibilityLabel(a.title).accessibilityAddTraits(selection == a ? .isSelected : [])
            }
        }
    }
}

/// A drop-down of every theme, grouped, with a live preview of the one selected.
struct ThemePicker: View {
    @Binding var selection: AppTheme
    @Binding var custom: CustomTheme
    /// Edited here and applied with a button: rebuilding the window on every drag of a colour would close the colour panel.
    @State private var draft = CustomTheme.standard

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Choose a theme") {
                Picker("Theme", selection: Binding(get: { selection }, set: { t in withAnimation(AnimationTokens.standard) { selection = t } })) {
                    ForEach(Array(AppTheme.Group.allCases.enumerated()), id: \.element) { i, g in
                        if i > 0 { Divider() }
                        Section(g.rawValue) {
                            ForEach(AppTheme.allCases.filter { $0.group == g }) { Text($0.rawValue).tag($0) }
                        }
                    }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
            }
            HStack(alignment: .center, spacing: 14) {
                tile(selection == .custom ? draft.palette : selection.palette).frame(width: 150)
                VStack(alignment: .leading, spacing: 3) {
                    Text(selection.rawValue).font(.headline)
                    Text(selection.subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("\(AppTheme.allCases.count) themes available").font(.caption).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            if selection == .custom { editor }
        }
        .padding(.vertical, 4)
        .onAppear { draft = custom }
        .onChange(of: selection) { _, t in if t == .custom { draft = custom } }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 18) {
                swatch("Background", \.background)
                swatch("Accent", \.accent)
                swatch("Text", \.text)
                Spacer(minLength: 0)
            }
            LabeledContent("Gloss") {
                HStack { Slider(value: $draft.gloss, in: 0...1).frame(width: 180); Text("\(Int(draft.gloss * 100))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing) }
            }
            if !draft.isReadable {
                Label(draft.textContrast < 4.5 ? "Text on this background is hard to read (contrast \(String(format: "%.1f", draft.textContrast)):1, aim for 4.5 or more)."
                                              : "The accent is hard to see on this background (contrast \(String(format: "%.1f", draft.accentContrast)):1).", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Button("Apply") { custom = draft }.disabled(draft == custom).keyboardShortcut(.defaultAction)
                Button("Revert") { draft = custom }.disabled(draft == custom)
                Button("Start Again") { draft = .standard; custom = .standard }.disabled(draft == .standard && custom == .standard)
            }
        }
    }

    private func swatch(_ title: String, _ key: WritableKeyPath<CustomTheme, UInt32>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ColorPicker(title, selection: Binding(get: { Color(hex: draft[keyPath: key]) }, set: { draft[keyPath: key] = Self.hex($0) }), supportsOpacity: false).labelsHidden()
        }
    }

    private static func hex(_ c: Color) -> UInt32 {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .black
        func b(_ v: CGFloat) -> UInt32 { UInt32(min(255, max(0, (v * 255).rounded()))) }
        return b(n.redComponent) << 16 | b(n.greenComponent) << 8 | b(n.blueComponent)
    }

    private func tile(_ p: ThemePalette) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(hex: p.background))
            HStack(spacing: 0) {
                ZStack {
                    Rectangle().fill(Color(hex: p.panel))
                    LinearGradient(colors: [Color.white.opacity(p.sheen), .clear], startPoint: .topLeading, endPoint: .center)
                    VStack(alignment: .leading, spacing: 5) {
                        Capsule().fill(Color(hex: p.accent)).frame(width: 22, height: 4)
                        Capsule().fill(Color(hex: p.textTertiary).opacity(0.7)).frame(width: 26, height: 3)
                        Capsule().fill(Color(hex: p.textTertiary).opacity(0.7)).frame(width: 20, height: 3)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8).padding(.top, 14).frame(maxHeight: .infinity, alignment: .top)
                }.frame(width: 42)
                VStack(alignment: .leading, spacing: 6) {
                    Capsule().fill(Color(hex: p.text).opacity(0.85)).frame(width: 44, height: 4)
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 3).fill(Color(hex: p.card)).frame(height: 26)
                        RoundedRectangle(cornerRadius: 3).fill(Color(hex: p.card)).frame(height: 26)
                    }
                    Capsule().fill(Color(hex: p.accent)).frame(width: 30, height: 8)
                }.padding(8)
            }
            if p.highlight > 0 { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(LinearGradient(colors: [Color.white.opacity(p.highlight), .clear], startPoint: .top, endPoint: .bottom), lineWidth: 1) }
        }
        .frame(height: 78).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .accessibilityHidden(true)
    }
}
