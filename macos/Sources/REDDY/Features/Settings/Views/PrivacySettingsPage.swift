import SwiftUI

struct PrivacySettingsPage: View {
    var body: some View {
        SettingsPage {
            ParentalSettingsGroup()
            AppLockSettingsGroup()
            ProxySettingsGroup()
            VPNSettingsGroup()
        }
    }
}
