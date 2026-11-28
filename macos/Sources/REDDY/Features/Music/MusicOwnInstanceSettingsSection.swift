import SwiftUI

/// Optional fields for the person's own Piped or Invidious server. A server of your own works where public ones are blocked. Nothing is
/// contacted until Test is pressed or a song needs audio; the addresses stay on this device.
struct MusicOwnInstanceSettingsSection: View {
    let hub: MusicHub
    @State private var model = OwnInstanceFields()

    var body: some View {
        MusicSettingsGroup(title: "Your own server", footer: "Optional. Use your own Piped or Invidious server if you run one: it works where public servers are blocked.") {
            fieldRow(.piped, title: "Piped server", prompt: "https://piped-api.example.org")
            fieldRow(.invidious, title: "Invidious server", prompt: "https://invidious.example.org")
            MusicToggleRow(title: "This is my own server on my network",
                           info: "Needed for an address on your home or office network, such as http://192.168.1.20:3000. Only the addresses you type here are allowed; no other private address is.",
                           isOn: Binding(get: { model.ownNetwork }, set: { model.ownNetwork = $0; model.persist() }))
            MusicSettingsRow(title: "Remove both addresses") {
                Button("Remove", role: .destructive) { model.removeAll() }.musicButton(.destructive, size: .compact)
                    .disabled(model.piped.isEmpty && model.invidious.isEmpty)
                    .accessibilityLabel(Text("Remove your own server addresses")).atlas("control.music.settingsOwnInstanceRemoveYourOwnServerAddresses")
            }
        }
        .onAppear { model.load() }
    }

    private func fieldRow(_ kind: YouTubeInstances.Kind, title: String, prompt: String) -> some View {
        let text = Binding<String>(get: { model.text(kind) }, set: { model.setText($0, kind) })
        return VStack(alignment: .leading, spacing: Spacing.xxs) {
            MusicSettingsRow(title: title) {
                HStack(spacing: Spacing.sm) {
                    TextField(prompt, text: text)
                        .textFieldStyle(.roundedBorder).frame(minWidth: 220, maxWidth: 320)
                        .autocorrectionDisabled()
                        .accessibilityLabel(Text(LocalizedStringKey(title)))
                    Button("Test") { model.test(kind, http: MusicHTTP()) }
                        .musicButton()
                        .disabled(model.testing.contains(kind) || model.problem(kind) != nil || model.text(kind).trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityLabel(Text("Test")).atlas("control.music.settingsOwnInstanceTest")
                }
            }
            if let line = model.problem(kind) {
                Text(verbatim: line).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).padding(.horizontal, Spacing.md)
            } else if let result = model.result[kind] {
                Text(verbatim: result).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).padding(.horizontal, Spacing.md)
                    .accessibilityLabel(Text(verbatim: result))
            }
        }
    }
}

/// The state behind the section: the text in each field, the saved setting and the last test line.
@MainActor @Observable
final class OwnInstanceFields {
    var piped = ""
    var invidious = ""
    var ownNetwork = false
    var result: [YouTubeInstances.Kind: String] = [:]
    var testing: Set<YouTubeInstances.Kind> = []

    func load() {
        let s = MusicOwnInstances.load()
        piped = s.piped.joined(separator: ", ")
        invidious = s.invidious.joined(separator: ", ")
        ownNetwork = s.ownNetwork
    }

    func text(_ kind: YouTubeInstances.Kind) -> String { kind == .piped ? piped : invidious }

    func setText(_ value: String, _ kind: YouTubeInstances.Kind) {
        if kind == .piped { piped = value } else { invidious = value }
        result[kind] = nil
        persist()
    }

    /// The first thing wrong with what is typed, as a plain sentence; nil when it is empty or fine.
    func problem(_ kind: YouTubeInstances.Kind) -> String? {
        for raw in MusicOwnInstances.split(text(kind)) {
            if case .failure(let p) = MusicOwnInstances.validate(raw, ownNetwork: ownNetwork) { return p.message }
        }
        return nil
    }

    /// Saves only the addresses that pass validation; a half-typed address is kept in the field but not stored.
    func persist() {
        func valid(_ t: String) -> [String] {
            MusicOwnInstances.split(t).compactMap { if case .success(let u) = MusicOwnInstances.validate($0, ownNetwork: ownNetwork) { u.absoluteString } else { nil } }
        }
        MusicOwnInstances(piped: valid(piped), invidious: valid(invidious), ownNetwork: ownNetwork).save()
    }

    func removeAll() {
        piped = ""; invidious = ""; ownNetwork = false; result = [:]
        MusicOwnInstances.removeAll()
        _ = MusicOwnInstances.current()   // refills the allow-list with only the music server hosts that remain
    }

    func test(_ kind: YouTubeInstances.Kind, http: MusicHTTP) {
        let urls = MusicOwnInstances.split(text(kind)).compactMap { raw -> URL? in
            if case .success(let u) = MusicOwnInstances.validate(raw, ownNetwork: ownNetwork) { return u } else { return nil }
        }
        guard !urls.isEmpty else { return }
        testing.insert(kind)
        result[kind] = Localized.string("Testing…")
        Task {
            var lines: [String] = []
            for u in urls {
                let status = await MusicOwnProbe.run(kind, base: u, http: http)
                lines.append(urls.count > 1 ? "\(u.host ?? u.absoluteString): \(status.line)" : status.line)
            }
            result[kind] = lines.joined(separator: "\n")
            testing.remove(kind)
        }
    }
}
