import SwiftUI

/// Your own Subsonic or Navidrome server: add up to three, check each one, remove it, and choose whether the server converts audio.
/// Nothing is contacted until Test is pressed or a song of the server is used; the address and user name stay on this device and the
/// password is kept in the Keychain.
struct MusicSubsonicSettingsSection: View {
    let hub: MusicHub
    @State private var model = SubsonicFields()

    var body: some View {
        VStack(alignment: .leading, spacing: MusicTokens.settingsGroupSpacing) {
            serversGroup
            addGroup
        }
        .onAppear { model.load() }
    }

    private var serversGroup: some View {
        MusicSettingsGroup(title: "Your music server", count: model.servers.isEmpty ? nil : Localized.string("%d of %d added", model.servers.count, SubsonicServers.max),
                           footer: "Optional. Add your own Subsonic or Navidrome server to play your own library, stars and playlists here.") {
            MusicToggleRow(title: "Use my music server",
                           info: "Turns your music server on as a source for search, browsing and playing. Turn it on to use it.",
                           isOn: Binding(get: { hub.registry.isEnabled(SubsonicProvider.providerID) }, set: { hub.registry.setEnabled($0, id: SubsonicProvider.providerID) }))
                .disabled(model.servers.isEmpty)
            if model.servers.isEmpty { MusicNote(text: "No server added yet.") }
            ForEach(model.servers) { server in serverRow(server) }
            MusicPickerRow(title: "Convert audio to", info: "Ask your server to convert songs while it plays them. Leave it on \"Server decides\" to play the files as they are.",
                           selection: Binding(get: { model.format }, set: { model.setFormat($0) }),
                           options: formatOptions)
            MusicPickerRow(title: "Highest bit rate", info: "The most data per second the server may use when it converts audio. It only applies when a format is chosen above or the server converts by itself.",
                           selection: Binding(get: { model.bitrate }, set: { model.setBitrate($0) }),
                           options: bitrateOptions)
        }
    }

    private var formatOptions: [(value: String, label: String)] {
        [(value: "", label: "Server decides")] + SubsonicTranscode.formats.map { (value: $0, label: $0.uppercased()) }
    }

    private var bitrateOptions: [(value: Int, label: String)] {
        [(value: 0, label: "Server decides")] + SubsonicTranscode.bitrates.map { (value: $0, label: Localized.string("%d kbps", $0)) }
    }

    private func serverRow(_ server: SubsonicServer) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            MusicSettingsRow(title: server.label) {
                HStack(spacing: Spacing.sm) {
                    Button("Test") { model.test(server) }
                        .musicButton().disabled(model.testing.contains(server.id))
                        .accessibilityLabel(Text(verbatim: Localized.string("Test %@", server.label))).atlas("control.music.settingsYourMusicServerTest")
                    Button("Remove", role: .destructive) { model.remove(server) }.musicButton(.destructive, size: .compact)
                        .accessibilityLabel(Text(verbatim: Localized.string("Remove %@", server.label))).atlas("control.music.settingsYourMusicServerRemove")
                }
            }
            if let line = model.results[server.id] {
                Text(verbatim: line).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).padding(.horizontal, Spacing.md)
            }
        }
    }

    private var addGroup: some View {
        MusicSettingsGroup(title: "Add a server", footer: "The password is kept in this device's Keychain. Only a salted hash of it is sent to your server, never the password itself.") {
            MusicFieldRow(title: "Server address", prompt: "https://music.example.org", text: $model.address)
            MusicFieldRow(title: "User name", text: $model.username)
            MusicFieldRow(title: "Password", secret: true, text: $model.password)
            MusicToggleRow(title: "This is my own server on my network",
                           info: "Needed for an address on your home or office network, such as http://192.168.1.20:4533. Only the addresses you add here are allowed; no other private address is.",
                           isOn: $model.ownNetwork)
            if let problem = model.problem { MusicNote(text: problem, tone: .warning) }
            MusicSettingsRow(title: "Check the details first") {
                HStack(spacing: Spacing.sm) {
                    Button("Test") { model.testTyped() }
                        .musicButton().disabled(!model.canTest || model.testingTyped)
                        .accessibilityLabel(Text("Test the server details")).atlas("control.music.settingsYourMusicServerTestTheServerDetails")
                    Button("Add server") { model.add() }
                        .musicButton(.primary).disabled(!model.canAdd)
                        .accessibilityLabel(Text("Add the music server")).atlas("control.music.settingsYourMusicServerAddTheMusicServer")
                }
            }
            if let line = model.message { MusicNote(text: line.text, tone: line.tone) }
        }
    }
}

/// The state behind the section: what is typed, the saved servers and the last result lines.
@MainActor @Observable
final class SubsonicFields {
    struct Line { var text: String; var tone: SettingsValueRow.Tone }

    var address = "" { didSet { message = nil } }
    var username = "" { didSet { message = nil } }
    var password = "" { didSet { message = nil } }
    var ownNetwork = false { didSet { message = nil } }
    private(set) var servers: [SubsonicServer] = []
    private(set) var results: [String: String] = [:]
    private(set) var testing: Set<String> = []
    private(set) var testingTyped = false
    private(set) var message: Line?
    private(set) var format = ""
    private(set) var bitrate = 0

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let http: MusicHTTP

    init(defaults: UserDefaults = .standard, http: MusicHTTP = MusicHTTP()) { self.defaults = defaults; self.http = http }

    func load() {
        servers = SubsonicServers.load(defaults)
        let t = SubsonicTranscode.load(defaults)
        format = t.format ?? ""; bitrate = t.maxBitRate ?? 0
    }

    /// The first thing wrong with the address as typed; nil when it is empty or fine.
    var problem: String? {
        guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if case .failure(let p) = SubsonicServers.validate(address, ownNetwork: ownNetwork) { return p.message }
        if servers.count >= SubsonicServers.max { return SubsonicServers.Problem.tooMany.message }
        return nil
    }

    private var filled: Bool {
        !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }
    var canTest: Bool { filled && problem == nil }
    var canAdd: Bool { filled && problem == nil && servers.count < SubsonicServers.max }

    func setFormat(_ value: String) {
        format = value
        SubsonicTranscode(format: value.isEmpty ? nil : value, maxBitRate: bitrate == 0 ? nil : bitrate).save(defaults)
    }

    func setBitrate(_ value: Int) {
        bitrate = value
        SubsonicTranscode(format: format.isEmpty ? nil : format, maxBitRate: value == 0 ? nil : value).save(defaults)
    }

    func add() {
        switch SubsonicServers.add(address: address, username: username, password: password, ownNetwork: ownNetwork, defaults: defaults) {
        case .success:
            address = ""; username = ""; password = ""; ownNetwork = false      // the password is not kept in memory longer than needed
            servers = SubsonicServers.load(defaults)
            message = Line(text: Localized.string("Server added. Switch it on above to use it."), tone: .good)
        case .failure(let p):
            message = Line(text: p.message, tone: .bad)
        }
    }

    func remove(_ server: SubsonicServer) {
        SubsonicServers.remove(id: server.id, defaults: defaults)
        results[server.id] = nil
        servers = SubsonicServers.load(defaults)
    }

    /// Checks what is typed, without saving it.
    func testTyped() {
        guard case .success(let url) = SubsonicServers.validate(address, ownNetwork: ownNetwork) else { return }
        let session = SubsonicSession(serverID: "test", base: url, user: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password, salt: SubsonicAuth.makeSalt())
        testingTyped = true
        message = Line(text: Localized.string("Testing…"), tone: .normal)
        let http = http
        Task {
            let status = await SubsonicProbe.run(session, http: http)
            message = Line(text: status.line, tone: status.isWorking ? .good : .warning)
            testingTyped = false
        }
    }

    func test(_ server: SubsonicServer) {
        guard let session = SubsonicServers.sessions([server], password: { MusicKeychain.shared.read($0) }).first else {
            results[server.id] = SubsonicStatus.wrongLogin.line; return
        }
        testing.insert(server.id)
        results[server.id] = Localized.string("Testing…")
        let http = http
        Task {
            let status = await SubsonicProbe.run(session, http: http)
            results[server.id] = status.line
            testing.remove(server.id)
        }
    }
}
