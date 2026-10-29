import SwiftUI

/// A proxy for the app's own requests (playlists, guides, details, pictures) and for streams played by the MPV engine.
struct ProxyView: View {
    @Environment(AppSettings.self) private var settings
    @State private var port = ""

    var body: some View {
        @Bindable var s = settings
        Form {
            Section {
                Picker("Type", selection: $s.proxyKind) { ForEach(ProxyConfig.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                if s.proxyKind != .off {
                    TextField("Host", text: $s.proxyHost).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Port", text: $port).keyboardType(.numberPad)
                        .onChange(of: port) { _, v in s.proxyPort = Int(v.filter(\.isNumber)) ?? 0 }
                }
            } footer: {
                Text("Sends playlist, guide, artwork and detail requests, and streams played by the MPV engine, through the proxy. MPV supports HTTP proxies only. Apple's player uses the system network settings and ignores this. This is a proxy for StreamSetu's own requests only, not a VPN: StreamSetu does not create a tunnel for the app or hide your address from the proxy.")
            }.listRowBackground(ColorTokens.surface)
        }
        .navigationTitle("Proxy").themed("Proxy")
        .onAppear { port = s.proxyPort > 0 ? String(s.proxyPort) : "" }
    }
}
