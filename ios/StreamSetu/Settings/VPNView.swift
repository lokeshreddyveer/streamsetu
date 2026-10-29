import SwiftUI

/// Shows whether a VPN is connected and, if asked, pauses playback when it drops. StreamSetu does not run or see inside a VPN.
struct VPNView: View {
    @Environment(\.container) private var container
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var s = settings
        let on = container?.vpn.isOn ?? false
        Form {
            Section {
                Label(on ? "A VPN connection is active" : "No VPN connection detected", systemImage: on ? "lock.shield.fill" : "lock.open")
                    .foregroundStyle(on ? Color.green : Color.secondary)
            } footer: { Text("To turn a VPN on or off, use Settings > General > VPN & Device Management, or your VPN provider's app.") }.listRowBackground(ColorTokens.surface)
            Section {
                Toggle("Pause if the VPN drops", isOn: $s.vpnPause)
            } footer: { Text("While something is playing, playback pauses if a connected VPN disconnects, so a stream does not carry on outside it. StreamSetu does not provide a VPN or an app-only VPN tunnel: it can only notice that a VPN set up on this device is on, and it never sees what that VPN does.") }.listRowBackground(ColorTokens.surface)
        }
        .navigationTitle("VPN").themed("VPN")
    }
}
