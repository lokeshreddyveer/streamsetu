import SwiftUI

// Devices: control Music on another of your devices on the same network, and let this one be controlled. Nothing here runs until the
// person acts: the host is off by default and looking for devices starts only on the button.

/// What the Devices page shows for a found device and for the search, as plain values so the mapping is tested.
enum MusicDevicesLogic {
    enum PeerState: Equatable, Sendable { case available, pairing, paired, connected }
    enum SearchState: Equatable, Sendable { case idle, searching, found(Int) }

    /// A found device is connected, paired (can be controlled at once), being paired (the code box is open) or new.
    static func peerState(isPaired: Bool, isConnected: Bool, codeOpen: Bool) -> PeerState {
        if isConnected { return .connected }
        if isPaired { return .paired }
        return codeOpen ? .pairing : .available
    }

    static func searchState(browsing: Bool, peerCount: Int) -> SearchState {
        guard browsing else { return .idle }
        return peerCount == 0 ? .searching : .found(peerCount)
    }

    /// The words on the row's button.
    static func actionTitle(_ state: PeerState) -> String {
        switch state { case .available: "Pair"; case .pairing: "Cancel"; case .paired: "Control"; case .connected: "Disconnect" }
    }

    /// The one primary action of a row is Control; the rest are secondary.
    static func actionIsPrimary(_ state: PeerState) -> Bool { state == .paired }

    static func chip(_ state: PeerState) -> (title: String, symbol: String, tone: MusicStatusTone) {
        switch state {
        case .available, .pairing: ("New", "circle.dashed", .neutral)
        case .paired: ("Paired", "link", .neutral)
        case .connected: ("Controlling", "checkmark.circle.fill", .good)
        }
    }

    static func searchChip(_ state: SearchState) -> (title: String, symbol: String, tone: MusicStatusTone)? {
        switch state {
        case .idle: nil
        case .searching: ("Searching", "dot.radiowaves.left.and.right", .neutral)
        case .found: ("Found", "checkmark.circle", .good)
        }
    }

    /// Only digits, at most six.
    static func cleanedCode(_ raw: String) -> String { String(raw.filter(\.isNumber).prefix(6)) }
}

struct MusicDevicesPage: View {
    let hub: MusicHub
    @State private var codeEntry: [String: String] = [:]
    @State private var pairingWith: String?
    @State private var seekValue: Double = 0
    @State private var seeking = false
    @State private var volumeValue: Double = 1
    @State private var confirmRevoke: MusicPairedDevice?
    @State private var searchedOnce = false
    @Environment(\.reddyAccent) private var accent

    private var devices: MusicDevices { hub.devices }
    private var host: MusicRemoteHost { devices.host }
    private var client: MusicRemoteClient { devices.client }

    var body: some View {
        MusicScreen(title: Localized.string("Devices")) {
            outputSection
            if client.status == .connected, let state = client.remote { remoteSection(state) }
            thisDeviceSection
            otherDevicesSection
        }
        .onDisappear { devices.discovery.stop() }
        .confirmationDialog("Remove this device?", isPresented: Binding(get: { confirmRevoke != nil }, set: { if !$0 { confirmRevoke = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) { if let d = confirmRevoke { devices.paired.revoke(d) }; confirmRevoke = nil }.atlas("control.music.devicesRemove")
            Button("Cancel", role: .cancel) { confirmRevoke = nil }.atlas("control.music.devicesCancel")
        } message: { Text("It will lose access at once and would need to pair again with a new code.") }
    }

    // MARK: where this device plays

    private var outputSection: some View {
        MusicPageSection("Playing on", footnote: "Applies to Music only. Music never takes a device away from other apps.") {
            MusicOutputCard(hub: hub)
        }
    }

    // MARK: this device as the one being controlled

    private var thisDetail: String {
        let kind = Localized.string(MusicDeviceKind.thisDevice.label)
        if !devices.allowControl { return kind + " · " + Localized.string("Not visible to other devices") }
        if host.error != nil { return kind + " · " + Localized.string("Could not start") }
        if host.isRunning { return kind + " · " + Localized.string("Visible on your network") }
        return kind + " · " + Localized.string("Starting...")
    }

    private var thisDeviceSection: some View {
        MusicPageSection("This device", footnote: "Off until you turn it on. Only commands travel, on your own network, and a device needs the code you show here.") {
            MusicDeviceCard(kind: .thisDevice, name: devices.deviceName, state: .thisDevice, detail: thisDetail) { _ in }
            MusicToggleRow(title: "Allow other devices to control this one", atlas: "control.music.devicesAllowOtherDevicesToControlThis",
                           info: "When this is on, this device becomes visible to other devices on your home network, and a device you have paired can play, pause, skip and change the volume here. It is off until you turn it on. No audio is sent, only commands and what is playing. Nothing outside your own network can connect, and nobody can control Music without first entering a code that you show here.",
                           isOn: Binding(get: { devices.allowControl }, set: { devices.setAllowControl($0) }))
            if let e = host.error { errorBanner(e, retryTitle: "Try again", atlas: "control.music.devicesTryAgain") { devices.setAllowControl(true) } }
            if devices.allowControl && host.isRunning { hostControls }
        }
    }

    @ViewBuilder private var hostControls: some View {
        MusicAdaptivePair {
            VStack(alignment: .leading, spacing: MusicSpace.xs) { pairingBlock }
        } second: {
            VStack(alignment: .leading, spacing: MusicSpace.xs) { controllersBlock }
        }
    }

    @ViewBuilder private var pairingBlock: some View {
        if let until = host.pairingLockedUntil {
            MusicStatusChip(title: Localized.string("Too many wrong codes. Pairing is locked until %@.", until.formatted(date: .omitted, time: .shortened)), symbol: "lock.fill", tone: .warning)
        } else if let code = host.pairingCode, let expires = host.pairingExpiresAt {
            MusicCodeCard(code: code, expires: expires, prompt: "Enter this code on the other device", spokenPrefix: Localized.string("Pairing code"),
                          timeFormat: "Works once, and for %d more seconds.", copyAtlas: "control.music.devicesCopyCode") { host.refreshPairing() }
            Button("Cancel") { host.closePairing() }.musicButton(.tertiary, size: .compact).atlas("control.music.devicesCancel")
        } else {
            Button("Show pairing code") { host.openPairing() }.musicButton(.secondary)
                .accessibilityLabel("Show a pairing code for another device").atlas("control.music.devicesShowAPairingCodeForAnother")
        }
    }

    @ViewBuilder private var controllersBlock: some View {
        Text("Allowed to control this device").musicText(.secondary).fontWeight(.semibold).foregroundStyle(ColorTokens.textSecondary)
        let controllers = devices.paired.controllers
        if controllers.isEmpty {
            Text("No device is allowed yet. Show a pairing code and enter it on the other device.").musicText(.secondary).foregroundStyle(ColorTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(controllers) { d in
            let connected = host.connectedNames.contains(d.name)
            MusicDeviceCard(kind: MusicDeviceKind.infer(name: d.name), name: d.name.isEmpty ? Localized.string("Unnamed device") : d.name,
                            state: connected ? .connected : .paired,
                            detail: Localized.string("Paired %@", d.pairedAt.formatted(date: .abbreviated, time: .omitted)),
                            actions: [.forget], forgetTitle: "Revoke") { _ in confirmRevoke = d }
        }
    }

    // MARK: finding and controlling other devices

    private var entries: [MusicDeviceEntry] {
        MusicDeviceList.entries(peers: devices.discovery.peers.map { ($0.id, $0.name) },
                                paired: devices.paired.hosts.map { ($0.deviceID, $0.name, $0.pairedAt) },
                                connectedID: client.status == .connected ? client.remoteID : nil, codeOpenID: pairingWith,
                                searching: devices.discovery.isBrowsing || searchedOnce)
    }

    private var otherDevicesSection: some View {
        let browsing = devices.discovery.isBrowsing
        let list = entries
        let search = MusicDevicesLogic.searchState(browsing: browsing, peerCount: devices.discovery.peers.count)
        let view = MusicDeviceDiscoveryView.decide(browsing: browsing, searchedOnce: searchedOnce, entryCount: list.count)
        return MusicPageSection("Other devices", footnote: "Uses your local network.", trailing: {
            if let chip = MusicDevicesLogic.searchChip(search) {
                MusicStatusChip(title: search == .searching ? chip.title : Localized.string("%d found", devices.discovery.peers.count), symbol: chip.symbol, tone: chip.tone)
            }
        }) {
            HStack(spacing: MusicSpace.sm) {
                Button { searchedOnce = true; devices.discovery.start() } label: {
                    HStack(spacing: MusicSpace.xs) {
                        if browsing { MusicLoadingIcon(size: MusicIconSize.small) } else { Image(systemName: "magnifyingglass").accessibilityHidden(true) }
                        Text("Look for my devices")
                    }
                }
                .musicButton(.primary).disabled(browsing).atlas("control.music.devicesLookForMyDevices")
                if browsing { Button("Stop looking") { devices.discovery.stop() }.musicButton(.secondary).atlas("control.music.devicesStopLooking") }
                if client.status == .connecting {
                    HStack(spacing: MusicSpace.xs) { MusicLoadingIcon(size: MusicIconSize.small); Text("Connecting to \(client.remoteName)").musicText(.secondary).foregroundStyle(ColorTokens.textSecondary) }
                }
            }
            if let n = devices.discovery.note {
                errorBanner(n, retryTitle: "Try again", atlas: "control.music.devicesTryAgain") { devices.discovery.stop(); devices.discovery.start() }
            }
            if case .failed(let text) = client.status {
                errorBanner(text, retryTitle: "Try again", atlas: "control.music.devicesTryAgain") { if let peer = devices.discovery.peers.first(where: { $0.id == client.remoteID }) { client.connect(to: peer, code: nil) } else { devices.discovery.stop(); devices.discovery.start() } }
            }
            switch view {
            case .invite:
                MusicEmptyState(glyph: .devices, title: Localized.string("Find your other devices"),
                                message: Localized.string("Look on your local network for devices running StreamSetu Music, pair once with a code, then control them from here."), compact: true)
            case .searchingEmpty, .none:
                MusicEmptyState(glyph: .devices, title: Localized.string("No devices found"),
                                message: view == .searchingEmpty ? Localized.string("Still looking on your local network.") : Localized.string("Nothing answered on your local network."), compact: true)
                MusicCheckList(title: "If nothing shows up, check that", items: [
                    "Both devices are on the same Wi-Fi or network.",
                    "StreamSetu Music is open on the other device.",
                    "Allow other devices to control this one is on there.",
                    "Local Network access is allowed for StreamSetu in System Settings.",
                ])
            case .list:
                MusicDeviceCardGrid {
                    ForEach(list) { e in deviceCard(e) }
                }
            }
        }
    }

    private func errorBanner(_ text: String, retryTitle: String?, atlas: String?, retry: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: MusicSpace.xs) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ColorTokens.danger).accessibilityHidden(true)
            Text(text.loc).musicText(.secondary).foregroundStyle(ColorTokens.textPrimary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: MusicSpace.xs)
            if let retryTitle, atlas != nil { Button(retryTitle.loc, action: retry).musicButton(.secondary, size: .compact).atlas("control.music.devicesTryAgain") }
        }
        .padding(MusicSpace.sm).frame(maxWidth: .infinity, alignment: .leading).musicCardSurface()
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func deviceCard(_ e: MusicDeviceEntry) -> some View {
        let peer = devices.discovery.peers.first { $0.id == e.id }
        MusicDeviceCard(kind: e.kind, name: e.name, state: e.state, detail: MusicDeviceText.detail(e), actions: e.actions) { action in
            switch action {
            case .control: if let peer { client.connect(to: peer, code: nil) }
            case .pair, .cancel: pairingWith = pairingWith == e.id ? nil : e.id
            case .disconnect: client.disconnect()
            case .forget: if let d = devices.paired.record(e.id, role: .host) { confirmRevoke = d }
            }
        } extra: {
            if e.state == .pairing, let peer { pairingEntry(peer) }
        }
    }

    private func pairingEntry(_ peer: MusicPeer) -> some View {
        VStack(alignment: .leading, spacing: MusicSpace.xxs) {
            HStack(spacing: MusicSpace.xs) {
                TextField("6-digit code", text: Binding(get: { codeEntry[peer.id] ?? "" }, set: { codeEntry[peer.id] = MusicDevicesLogic.cleanedCode($0) }))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: MusicTokens.settingsControlWidth).font(.system(.body, design: .monospaced))
                    .onSubmit { pair(peer) }
                    .accessibilityLabel("Pairing code shown on \(peer.name)")
                Button("Pair") { pair(peer) }.musicButton(.primary, size: .compact)
                    .disabled((codeEntry[peer.id] ?? "").count != 6).atlas("control.music.devicesPair")
            }
            Text(verbatim: Localized.string("On %@, turn on the setting and tap Show pairing code.", peer.name)).musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
        }
    }

    private func pair(_ peer: MusicPeer) {
        client.connect(to: peer, code: codeEntry[peer.id] ?? "")
        codeEntry[peer.id] = ""
        pairingWith = nil
    }

    // MARK: the remote

    private func remoteSection(_ s: MusicRemoteState) -> some View {
        MusicPageSection(Localized.string("Controlling %@", client.remoteName)) {
            HStack(spacing: MusicSpace.md) {
                MusicArtwork(s.artworkURL.map { [MusicThumbnail(url: $0)] } ?? [], size: MusicTokens.previewArtwork, corner: MusicCorner.compactCard)
                VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                    Text(verbatim: s.hasTrack ? s.title : Localized.string("Nothing is playing")).musicText(.section).lineLimit(2)
                    if s.hasTrack { Text(verbatim: s.artist).musicText(.body).foregroundStyle(ColorTokens.textSecondary).lineLimit(1) }
                    if s.queueCount > 0 {
                        Text(verbatim: Localized.string("Queue: %1$@ of %2$@", String((s.queueIndex ?? 0) + 1), String(s.queueCount))).musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: MusicSpace.sm) {
                transport("backward.fill", "Previous", variant: .icon) { client.send(.previous) }
                transport(s.isPlaying ? "pause.fill" : "play.fill", s.isPlaying ? "Pause" : "Play", variant: .primary) { client.send(s.isPlaying ? .pause : .play) }
                transport("forward.fill", "Next", variant: .icon) { client.send(.next) }
            }
            if s.hasTrack && s.duration > 0 {
                HStack(spacing: MusicSpace.xs) {
                    Text(verbatim: clock(seeking ? seekValue : s.position)).font(Typography.timestamp).foregroundStyle(ColorTokens.textTertiary)
                    Slider(value: Binding(get: { seeking ? seekValue : s.position }, set: { seekValue = $0 }), in: 0...max(1, s.duration)) { editing in
                        if editing { seekValue = s.position }
                        seeking = editing
                        if !editing { client.send(.seek(seekValue)) }
                    }
                    .tint(accent).accessibilityLabel("Position on \(client.remoteName)")
                    Text(verbatim: clock(s.duration)).font(Typography.timestamp).foregroundStyle(ColorTokens.textTertiary)
                }
            }
            HStack(spacing: MusicSpace.xs) {
                Image(systemName: "speaker.fill").foregroundStyle(ColorTokens.textTertiary).accessibilityHidden(true)
                Slider(value: Binding(get: { volumeValue }, set: { volumeValue = $0; client.send(.volume($0)) }), in: 0...1)
                    .frame(maxWidth: MusicTokens.settingsFieldWidth).tint(accent).accessibilityLabel("Volume on \(client.remoteName)")
                    .onAppear { volumeValue = s.volume }
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(ColorTokens.textTertiary).accessibilityHidden(true)
            }
            if !s.upNext.isEmpty {
                Text("Up next").musicText(.secondary).foregroundStyle(ColorTokens.textSecondary)
                ForEach(Array(s.upNext.enumerated()), id: \.offset) { _, t in Text(verbatim: t).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary).lineLimit(1) }
            }
            HStack(spacing: MusicSpace.sm) {
                Button("Play what is playing here, there") { sendHere() }.musicButton(.secondary)
                    .disabled(hub.player.queue.isEmpty)
                    .accessibilityLabel("Send this device's queue to \(client.remoteName)").atlas("control.music.devicesSendThisDeviceSQueueTo")
                Button("Disconnect") { client.disconnect() }.musicButton(.tertiary).atlas("control.music.devicesDisconnect")
            }
        }
    }

    private func transport(_ symbol: String, _ label: String, variant: MusicButtonVariant, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: MusicIconSize.row, weight: .semibold)) }
            .musicButton(variant, size: .large).help(Text(label.loc)).accessibilityLabel(Text(label.loc)).atlas("control.music.devicesMusicdevicespagetransportButton")
    }

    /// Hands this device's queue to the other one, starting at the current track. Only titles and ids travel, never audio.
    private func sendHere() {
        let player = hub.player
        let tracks = Array(player.queue.prefix(MusicRemoteLimits.maxQueueTracks))
        guard !tracks.isEmpty else { return }
        client.send(.playTrack(tracks.map { MusicRemoteTrack($0) }, startAt: min(player.index ?? 0, tracks.count - 1)))
    }

    private func clock(_ t: Double) -> String {
        let s = Int(max(0, t)); return String(format: "%d:%02d", s / 60, s % 60)
    }
}
