import SwiftUI

/// Settings, Library: Trakt and debrid accounts.
struct IntegrationsGroup: View {
    @Environment(\.container) private var container
    var body: some View {
        if let container {
            SettingsGroup(title: "Trakt", footer: "") { TraktPanel(container: container) }
            SettingsGroup(title: "Debrid", footer: "") { DebridPanel(container: container) }
            SettingsGroup(title: "AI assistant", footer: "") { AISettingsPanel(container: container) }
        }
    }
}
