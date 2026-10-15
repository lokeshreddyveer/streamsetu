import SwiftUI

struct AppearanceSettingsPage: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var s = settings
        SettingsPage {
            SettingsGroup(title: "Theme", footer: "Every theme is dark and restyles the whole app, including the sidebar, at once.") {
                ThemePicker(selection: $s.theme, custom: $s.customTheme)
            }

            SettingsGroup(title: "Appearance") {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accent colour")
                        Text("Used for the selected tab, buttons and progress. The first swatch follows the theme.").font(.callout).foregroundStyle(.secondary)
                    }
                    AccentPicker(selection: $s.accent)
                }
                .padding(.vertical, 2)
                SettingsRow(title: "Language", detail: "The language of the app's own wording. Titles and descriptions come from your playlists and stay as they are. Some text is still in English.") {
                    Picker("Language", selection: $s.language) { ForEach(AppLanguage.allCases) { Text($0.label).tag($0) } }.pickerStyle(.menu).fixedSize()
                }
                SettingsRow(title: "Density", detail: "Card size in grids, and row height in channel lists and the sidebar.") {
                    Picker("Density", selection: $s.density) { ForEach(LayoutDensity.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu).fixedSize()
                }
                SettingsRow(title: "Reduce animation", detail: "Turns off transitions and hover animation throughout the app.") { Toggle("Reduce animation", isOn: $s.reduceMotion) }
                SettingsRow(title: "Increase contrast", detail: "Brighter text and stronger outlines. Also follows the system Increase Contrast setting.") { Toggle("Increase contrast", isOn: $s.highContrast) }
                SettingsRow(title: "Sidebar at launch", detail: "The sidebar can always be collapsed from its header.", divider: false) {
                    Picker("Sidebar at launch", selection: $s.sidebarLaunch) { ForEach(SidebarLaunch.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu).fixedSize()
                }
            }
        }
    }
}
