import SwiftUI

/// Encrypted DNS for StreamSetu's own traffic. Not a VPN: nothing outside the app changes.
struct AppDNSView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @State private var testing = false
    @State private var result: AppDNSTestResult?
    @State private var bootstrapText = ""
    @State private var customProblem: String?

    var body: some View {
        @Bindable var s = settings
        Form {
            Section {
                Toggle("Use App DNS", isOn: $s.appDNS.enabled)
                NavigationLink {
                    ProviderList(config: $s.appDNS)
                } label: { LabeledContent("DNS provider", value: s.appDNS.provider.rawValue) }
                Toggle("Use system DNS for local devices", isOn: $s.appDNS.localUsesSystem)
                LabeledContent("Status") { Text(AppDNSStatus.line(s.appDNS, mpvInUse: false)).multilineTextAlignment(.trailing).foregroundStyle(.secondary) }
            } footer: {
                Text("Looks up server names through the DNS provider you choose, inside StreamSetu only. It is not a VPN and changes nothing else on this device. It can fix DNS blocking; it cannot get past IP blocking, routing problems or geographic limits. \(s.appDNS.provider.summary).")
            }.listRowBackground(ColorTokens.surface)

            if s.appDNS.provider == .custom {
                Section("Custom DNS") {
                    TextField("Name", text: $s.appDNS.customName)
                    TextField("https://example.com/dns-query", text: $s.appDNS.customURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Bootstrap IP addresses (optional, comma separated)", text: $bootstrapText).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onChange(of: bootstrapText) { _, v in s.appDNS.customBootstrap = v.split(whereSeparator: { ",; ".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) } }
                    if let customProblem { Text(customProblem).font(.footnote).foregroundStyle(.red) }
                }.listRowBackground(ColorTokens.surface)
            }

            Section {
                Button { Task { await runTest() } } label: { HStack { Text("Test App DNS"); if testing { Spacer(); ProgressView() } } }.disabled(testing)
                Button("Clear DNS Cache") { AppDNSController.clearCache(); container?.http.setProxy(settings.proxy.isActive ? settings.proxy : nil); state.toasts.show("DNS cache cleared", symbol: "checkmark.circle") }
            }.listRowBackground(ColorTokens.surface)

            if let r = result {
                Section {
                    Label(r.headline, systemImage: r.reachable ? "checkmark.seal" : "exclamationmark.triangle").foregroundStyle(r.reachable ? .green : .orange)
                    if r.reachable { LabeledContent("Resolver", value: "\(r.milliseconds) ms") }
                    ForEach(r.rows) { row in LabeledContent(row.label) { Text(row.detail).foregroundStyle(row.resolved ? Color.secondary : Color.orange).multilineTextAlignment(.trailing) } }
                    if let c = r.comparison { Text(c).font(.footnote) }
                    if !r.advice.isEmpty { Text(r.advice).font(.footnote) }
                }.listRowBackground(ColorTokens.surface)
            }

            Section { Text(AppDNSStatus.privacyNotice).font(.footnote).foregroundStyle(.secondary) }.listRowBackground(Color.clear)
        }
        .navigationTitle("App DNS").themed("App DNS")
        .onAppear { bootstrapText = s.appDNS.customBootstrap.joined(separator: ", ") }
        .onChange(of: s.appDNS.customURL) { _, v in
            if case .failure(let p) = AppDNSValidator.validate(v), !v.isEmpty { customProblem = p.description } else { customProblem = nil }
        }
    }

    private func runTest() async {
        guard let c = container else { return }
        testing = true; defer { testing = false }
        let sources = ((try? c.catalog.sources()) ?? []).filter { $0.id == state.activeSourceID || state.activeSourceID == nil }
        var hosts: [(label: String, address: String)] = []
        for src in sources.prefix(1) { hosts.append(("Playlist provider", src.baseURL)); if let g = src.epgURL { hosts.append(("Guide", g)) } }
        result = await AppDNSTest.run(settings.appDNS, hosts: hosts)
    }
}

private struct ProviderList: View {
    @Binding var config: AppDNSConfiguration
    var body: some View {
        List {
            ForEach(AppDNSProvider.allCases, id: \.self) { p in
                Button { config.provider = p } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) { Text(p.rawValue).foregroundStyle(.primary); Text(p.summary).font(.footnote).foregroundStyle(.secondary) }
                        Spacer()
                        if config.provider == p { Image(systemName: "checkmark").foregroundStyle(ColorTokens.accentDefault) }
                    }
                }
            }
        }.navigationTitle("DNS provider").themed("DNS provider")
    }
}
