import SwiftUI

/// What StreamSetu keeps and what it can send, as it is now.
struct PrivacyReportGroup: View {
    @Environment(\.container) private var container
    var body: some View {
        if let container {
            SettingsGroup(title: "Privacy report", footer: "This follows the privacy policy and shows your current settings. Nothing here is sent anywhere.") { PrivacyReportView(container: container) }
        }
    }
}

struct PrivacySettingsPage: View {
    var body: some View {
        SettingsPage {
            PrivacyReportGroup()
            ParentalSettingsGroup()
            AppLockSettingsGroup()
            ProxySettingsGroup()
            AppDNSSettingsGroup()
            VPNSettingsGroup()
        }
    }
}
