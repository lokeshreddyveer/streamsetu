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
        TabView(selection: $tab) {
            GeneralSettingsPage().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            AppearanceSettingsPage().tabItem { Label("Appearance", systemImage: "paintbrush") }.tag(SettingsTab.appearance)
            PlaybackSettingsPage().tabItem { Label("Playback", systemImage: "play.rectangle") }.tag(SettingsTab.playback)
            LibrarySettingsPage(vm: library).tabItem { Label("Library", systemImage: "books.vertical") }.tag(SettingsTab.library)
            PrivacySettingsPage().tabItem { Label("Privacy", systemImage: "hand.raised") }.tag(SettingsTab.privacy)
            AdvancedSettingsPage(vm: advanced).tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }.tag(SettingsTab.advanced)
        }
        .frame(width: 720)
        .frame(minHeight: 520, idealHeight: 760, maxHeight: 900)
        .reddyTheme(settings)
    }
}
