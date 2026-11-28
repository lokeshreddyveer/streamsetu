import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General", appearance = "Appearance", playback = "Playback", library = "Library", privacy = "Privacy", advanced = "Advanced"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .general: "gearshape"; case .appearance: "paintbrush"; case .playback: "play.rectangle"; case .library: "books.vertical"; case .privacy: "hand.raised"; case .advanced: "wrench.and.screwdriver" }
    }
}

/// The Settings window: the system's tabbed settings layout with grouped forms. Every control saves the moment it changes.
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var tab: SettingsTab = .general
    @State private var library = LibrarySettingsViewModel()
    @State private var advanced = AdvancedSettingsViewModel()

    var body: some View {
        // Ask Setu sits in a row of its own above the tabs, not over them: no label or control of any page can ever be hidden under it.
        VStack(spacing: 0) {
            if AssistantFeature.isOn { HStack(spacing: 0) {
                Spacer(minLength: 0)
                Button { AssistantLauncher.shared.ask("I need help with a setting or a problem. What can you check?"); AssistantLauncher.bringMainWindowForward() } label: { Label("Ask Setu", systemImage: "sparkles").font(.callout) }
                    .buttonStyle(.bordered).controlSize(.small).help("Ask the assistant about a setting, or to diagnose a problem").atlas("screen.assistant")
            }
            .padding(.horizontal, 16).padding(.vertical, 8) }
            TabView(selection: $tab) {
                GeneralSettingsPage().atlasScreen("screen.settings.general").tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
                AppearanceSettingsPage().atlasScreen("screen.settings.appearance").tabItem { Label("Appearance", systemImage: "paintbrush") }.tag(SettingsTab.appearance)
                PlaybackSettingsPage().atlasScreen("screen.settings.playback").tabItem { Label("Playback", systemImage: "play.rectangle") }.tag(SettingsTab.playback)
                LibrarySettingsPage(vm: library).atlasScreen("screen.settings.library").tabItem { Label("Library", systemImage: "books.vertical") }.tag(SettingsTab.library)
                PrivacySettingsPage().atlasScreen("screen.settings.privacy").tabItem { Label("Privacy", systemImage: "hand.raised") }.tag(SettingsTab.privacy)
                AdvancedSettingsPage(vm: advanced).atlasScreen("screen.settings.advanced").tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }.tag(SettingsTab.advanced)
            }
        }
        .onAppear { if let t = AtlasNavRequests.shared.takeSettingsTab(), let st = SettingsTab(rawValue: t) { tab = st } }
        .onChange(of: AtlasNavRequests.shared.settingsTab) { _, t in if let t, let st = SettingsTab(rawValue: t) { tab = st; _ = AtlasNavRequests.shared.takeSettingsTab() } }
        .frame(width: 720)
        .frame(minHeight: 520, idealHeight: 760, maxHeight: 900)
        .reddyTheme(settings)
    }
}
