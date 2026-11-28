import SwiftUI

// Listen Together: several devices on the same home network hear the same song at the same moment. Each device plays its own audio, so
// nothing but timing travels. Hosting is off until the person starts a room; looking for rooms starts only on the button. Everything on
// this page comes from the room session and the room host; nothing is invented.

struct MusicRoomPage: View {
    let hub: MusicHub
    @State private var codeEntry: [String: String] = [:]
    @State private var joining: String?
    @State private var searchedOnce = false
    @Environment(\.reddyAccent) private var accent

    private var room: MusicRoomSession { hub.room }
    private var host: MusicRoomHost { room.host }

    private var layout: MusicRoomLayout {
        MusicRoomLayout.decide(role: room.role, status: room.status, hostOpen: host.isOpen,
                               guestCount: host.participants.filter { !$0.isHost }.count, pendingCount: host.pendingJoins.count)
    }

    var body: some View {
        MusicScreen(title: Localized.string("Listen Together")) {
            if case .ended(let why) = room.status, room.role == .none { banner(why, symbol: "info.circle.fill", tint: ColorTokens.textSecondary) }
            if let e = room.errorMessage { banner(e, symbol: "exclamationmark.triangle.fill", tint: ColorTokens.danger) }
            switch layout {
            case .idle: idleContent
            case .hostWaiting, .hostActive: hostContent
            case .joining, .listening, .hostLost: guestContent
            }
        }
        .onDisappear { room.discovery.stop() }
    }

    private func banner(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: MusicSpace.xs) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            Text(text.loc).musicText(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(MusicSpace.sm).frame(maxWidth: .infinity, alignment: .leading).musicCardSurface()
        .accessibilityElement(children: .combine)
    }

    // MARK: no room yet

    private var idleContent: some View {
        MusicAdaptivePair {
            hostStartSection
        } second: {
            joinSection
        }
    }

    private var hostStartSection: some View {
        MusicPageSection("Host a room", footnote: "Off until you turn it on. Only timing travels, on your own network, and you approve everyone who joins.") {
            MusicToggleRow(title: "Start a room on this device", atlas: "control.music.listeningRoomStartARoomOnThisDevice",
                           info: "When this is on, other devices on your home network can see your room and ask to join with a 6-digit code you show here. You approve every person and every song they suggest. Each device plays its own audio, so no music is sent, only timing. Nothing outside your own network can connect. It is off until you turn it on, and it stops when you turn it off or quit.",
                           isOn: Binding(get: { room.isHosting }, set: { $0 ? room.startRoom() : room.closeRoom() }))
            if let e = host.error { banner(e, symbol: "exclamationmark.triangle.fill", tint: ColorTokens.danger) }
            MusicEmptyState(glyph: .note, title: Localized.string("Listen together"),
                            message: Localized.string("Start a room and share its code. Everyone on your Wi-Fi hears the same song at the same moment, each on their own device."), compact: true)
        }
    }

    // MARK: hosting

    private var hostContent: some View {
        let people = MusicRoomOrdering.ordered(host.participants, selfName: nil)
        let guests = people.filter { !$0.isHost }
        let shown = people.isEmpty ? [MusicRoomPerson(id: "host", name: room.deviceName, isHost: true, isYou: false)] : people
        return VStack(alignment: .leading, spacing: MusicSpace.xl) {
            MusicRoomHeaderCard(name: host.roomName.isEmpty ? room.deviceName : host.roomName,
                                detail: guests.isEmpty ? Localized.string("Nobody has joined yet.") : Localized.string("In the room (%1$@ of %2$@)", String(guests.count), String(MusicRoomLimits.maxGuests)),
                                people: shown, chip: .init(title: "Room open", symbol: "dot.radiowaves.left.and.right", tone: .good)) {
                Button("End room") { room.closeRoom() }.musicButton(.destructive, size: .compact)
                    .accessibilityLabel("End the room for everyone").atlas("control.music.listeningRoomEndRoom")
            }
            if let e = host.error { banner(e, symbol: "exclamationmark.triangle.fill", tint: ColorTokens.danger) }
            if !host.pendingJoins.isEmpty { requestsSection }
            MusicAdaptivePair {
                inviteSection
            } second: {
                peopleSection(guests: guests, all: people)
            }
            hostQueueSection
        }
    }

    private var requestsSection: some View {
        MusicPageSection("Waiting to join") {
            ForEach(host.pendingJoins) { p in
                MusicRequestCard(name: p.name, title: Localized.string("%@ wants to join", p.name)) {
                    Button("Let in") { host.approveJoin(p.id) }.musicButton(.primary, size: .compact).accessibilityLabel("Let \(p.name) in").atlas("control.music.listeningRoomLetIn")
                    Button("Refuse") { host.denyJoin(p.id) }.musicButton(.secondary, size: .compact).accessibilityLabel("Refuse \(p.name)").atlas("control.music.listeningRoomRefuse")
                }
            }
        }
    }

    private var inviteSection: some View {
        MusicPageSection("Invite", footnote: "Share the code. A guest on the same network opens Listen Together, looks for rooms and enters it, and you let them in.") {
            if let until = host.lockedUntil {
                MusicStatusChip(title: Localized.string("Too many wrong codes. New guests are locked out until %@.", until.formatted(date: .omitted, time: .shortened)), symbol: "lock.fill", tone: .warning)
            } else if let code = host.code, let expires = host.codeExpiresAt {
                MusicRoomInviteCard(roomName: host.roomName.isEmpty ? room.deviceName : host.roomName, code: code, expires: expires) { host.refreshCode() }
            } else {
                banner("The code has expired.", symbol: "clock.badge.exclamationmark", tint: ColorTokens.warning)
            }
            if host.lockedUntil == nil {
                Button("Show a new code") { host.newCode() }.musicButton(.secondary, size: .compact)
                    .accessibilityLabel("Show a new room code").atlas("control.music.listeningRoomShowANewRoomCode")
            }
        }
    }

    private func peopleSection(guests: [MusicRoomPerson], all: [MusicRoomPerson]) -> some View {
        MusicPageSection("People", trailing: {
            Text(verbatim: "\(guests.count)/\(MusicRoomLimits.maxGuests)").font(Typography.timestamp).monospacedDigit().foregroundStyle(ColorTokens.textSecondary)
        }) {
            if guests.isEmpty {
                MusicEmptyState(glyph: .devices, title: Localized.string("Nobody has joined yet."),
                                message: Localized.string("Share the code from this page. People appear here once you let them in."), compact: true)
            }
            ForEach(all) { p in MusicPersonCard(person: p, onRemove: p.isHost ? nil : { host.kick(p.id) }) }
        }
    }

    private var hostQueueSection: some View {
        let window = hub.player.roomQueueWindow
        let now = window.first.map { MusicRoomQueueLine(id: 0, title: $0.title, artist: $0.artistLine) }
        let next = window.dropFirst().prefix(5).enumerated().map { MusicRoomQueueLine(id: $0.offset + 1, title: $0.element.title, artist: $0.element.artistLine) }
        return MusicPageSection("Queue") {
            ForEach(host.pendingSuggestions) { s in
                MusicRequestCard(name: s.guestName, title: s.track.title, detail: Localized.string("%1$@ · suggested by %2$@", s.track.artists.joined(separator: ", "), s.guestName), symbol: "music.note") {
                    Button("Add") { host.approveSuggestion(s.id) }.musicButton(.primary, size: .compact).accessibilityLabel("Add \(s.track.title) to the queue").atlas("control.music.listeningRoomAddToTheQueue")
                    Button("No") { host.denySuggestion(s.id) }.musicButton(.secondary, size: .compact).accessibilityLabel("Do not add \(s.track.title)").atlas("control.music.listeningRoomDoNotAdd")
                }
            }
            MusicRoomQueueCard(now: now, isPlaying: hub.player.isPlaying, upNext: Array(next),
                               footnote: "Only you control playback. Guests can suggest songs, and you decide which are added.")
        }
    }

    // MARK: joining

    private var joinSection: some View {
        let browsing = room.discovery.isBrowsing
        let rooms = room.discovery.rooms
        return MusicPageSection("Join a room", footnote: "Uses your local network. The host shows a 6-digit code and lets you in.", trailing: {
            if browsing {
                MusicStatusChip(title: rooms.isEmpty ? Localized.string("Searching") : Localized.string("%d found", rooms.count),
                                symbol: rooms.isEmpty ? "dot.radiowaves.left.and.right" : "checkmark.circle", tone: rooms.isEmpty ? .neutral : .good)
            }
        }) {
            HStack(spacing: MusicSpace.sm) {
                Button { searchedOnce = true; room.discovery.start() } label: {
                    HStack(spacing: MusicSpace.xs) {
                        if browsing { MusicLoadingIcon(size: MusicIconSize.small) } else { Image(systemName: "magnifyingglass").accessibilityHidden(true) }
                        Text("Look for rooms")
                    }
                }
                .musicButton(.primary).disabled(browsing).atlas("control.music.listeningRoomLookForRooms")
                if browsing { Button("Stop looking") { room.discovery.stop() }.musicButton(.secondary).atlas("control.music.listeningRoomStopLooking") }
            }
            if let n = room.discovery.note { banner(n, symbol: "exclamationmark.triangle.fill", tint: ColorTokens.warning) }
            if rooms.isEmpty {
                if browsing || searchedOnce {
                    MusicEmptyState(glyph: .devices, title: Localized.string("No rooms found"),
                                    message: browsing ? Localized.string("Still looking on your local network.") : Localized.string("Nothing answered on your local network."), compact: true)
                    MusicCheckList(title: "If nothing shows up, check that", items: [
                        "The host has started a room.",
                        "Both devices are on the same Wi-Fi or network.",
                        "Local Network access is allowed for StreamSetu in System Settings.",
                    ])
                }
            } else {
                ForEach(rooms) { r in roomCard(r) }
            }
        }
    }

    private func roomCard(_ r: MusicPeer) -> some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            HStack(spacing: MusicSpace.sm) {
                MusicAvatar(name: r.name, size: MusicDeviceMetrics.tile)
                VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                    Text(verbatim: r.name).musicText(.card).lineLimit(1)
                    Text("Room on your network").musicText(.caption).foregroundStyle(ColorTokens.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                MusicStatusChip(title: "Open", symbol: "dot.radiowaves.left.and.right", tone: .good)
                Button((joining == r.id ? "Cancel" : "Join").loc) { joining = joining == r.id ? nil : r.id }
                    .musicButton(joining == r.id ? .tertiary : .primary, size: .compact).accessibilityLabel("Join the room on \(r.name)").atlas("control.music.listeningRoomJoinTheRoomOn")
            }
            if joining == r.id {
                HStack(spacing: MusicSpace.xs) {
                    TextField("6-digit code", text: Binding(get: { codeEntry[r.id] ?? "" }, set: { codeEntry[r.id] = MusicDevicesLogic.cleanedCode($0) }))
                        .textFieldStyle(.roundedBorder).frame(maxWidth: MusicTokens.settingsControlWidth).font(.system(.body, design: .monospaced))
                        .onSubmit { join(r) }
                        .accessibilityLabel("Room code shown on \(r.name)")
                    Button("Join") { join(r) }.musicButton(.primary, size: .compact).disabled((codeEntry[r.id] ?? "").count != 6).atlas("control.music.listeningRoomJoin")
                }
            }
        }
        .padding(MusicSpace.sm).musicCardSurface()
        .accessibilityElement(children: .contain)
    }

    private func join(_ r: MusicPeer) {
        room.join(r, code: codeEntry[r.id] ?? "")
        codeEntry[r.id] = ""
        joining = nil
        room.discovery.stop()
    }

    // MARK: following

    private var headerChip: MusicDeviceCardState.Chip {
        switch room.status {
        case .joined: .init(title: "Listening together", symbol: "checkmark.circle.fill", tone: .good)
        case .hostConnectionLost: .init(title: "Lost contact", symbol: "wifi.exclamationmark", tone: .bad)
        default: .init(title: "Joining", symbol: "clock", tone: .neutral)
        }
    }

    private var guestContent: some View {
        let people = MusicRoomOrdering.ordered(room.participants, selfName: room.deviceName)
        return VStack(alignment: .leading, spacing: MusicSpace.xl) {
            MusicRoomHeaderCard(name: room.roomName, detail: Localized.string(room.status.text), people: people, chip: headerChip) {
                Button((layout.isFollowing ? "Leave the room" : "Cancel").loc) { room.leave() }.musicButton(.secondary, size: .compact)
                    .accessibilityLabel("Leave the room").atlas("control.music.listeningRoomLeaveTheRoom")
            }
            if layout == .joining {
                HStack(spacing: MusicSpace.xs) { MusicLoadingIcon(size: MusicIconSize.small); Text(room.status.text.loc).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary) }
            }
            if layout.isFollowing { followingContent(people: people) }
        }
    }

    private func followingContent(people: [MusicRoomPerson]) -> some View {
        let sync = MusicSyncState.resolve(status: room.status, hasClock: room.clockSample != nil, adjusting: room.isAdjustingToHost,
                                          hasSourceProblem: room.trackNote != nil, hasTrack: room.nowPlaying != nil)
        let now = room.nowPlaying.map { MusicRoomQueueLine(id: 0, title: $0.title, artist: $0.artists.joined(separator: ", ")) }
        let next = room.queueWindow.dropFirst().prefix(5).enumerated().map { MusicRoomQueueLine(id: $0.offset + 1, title: $0.element.title, artist: $0.element.artists.joined(separator: ", ")) }
        return VStack(alignment: .leading, spacing: MusicSpace.xl) {
            MusicAdaptivePair {
                MusicPageSection("Now playing") {
                    MusicRoomQueueCard(now: now, isPlaying: hub.player.isPlaying, upNext: Array(next), footnote: "Only the host changes the queue. You can suggest a song below.")
                    if let note = room.trackNote { banner(note, symbol: "speaker.slash.fill", tint: ColorTokens.warning) }
                }
            } second: {
                MusicPageSection("On this device") {
                    if let sync { MusicSyncCard(state: sync, roundTripMillis: MusicSyncState.roundTripMillis(room.clockSample)) }
                    controls
                    suggestMenu
                    if let s = room.suggestionNote { Text(verbatim: s).musicText(.caption).foregroundStyle(ColorTokens.textTertiary) }
                }
            }
            MusicPageSection("People", trailing: {
                Text(verbatim: "\(people.count)").font(Typography.timestamp).monospacedDigit().foregroundStyle(ColorTokens.textSecondary)
            }) {
                MusicDeviceCardGrid { ForEach(people) { p in MusicPersonCard(person: p) } }
            }
        }
    }

    /// Play, pause and seek are shown greyed because the host drives them; only the volume is the guest's own.
    private var controls: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            HStack(spacing: MusicSpace.lg) {
                Image(systemName: "backward.fill"); Image(systemName: "playpause.fill"); Image(systemName: "forward.fill")
            }
            .font(.system(size: MusicIconSize.row, weight: .semibold)).foregroundStyle(ColorTokens.textTertiary)
            .accessibilityElement(children: .ignore).accessibilityLabel("Playback controls are off while you are in a room")
            Text(MusicRoomSession.lockExplanation.loc).musicText(.caption).foregroundStyle(ColorTokens.textTertiary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: MusicSpace.xs) {
                Image(systemName: "speaker.fill").foregroundStyle(ColorTokens.textTertiary).accessibilityHidden(true)
                Slider(value: Binding(get: { Double(hub.player.volume) }, set: { hub.player.volume = Float($0) }), in: 0...1)
                    .tint(accent).accessibilityLabel("Volume")
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(ColorTokens.textTertiary).accessibilityHidden(true)
            }
        }
        .padding(MusicSpace.sm).frame(maxWidth: .infinity, alignment: .leading).musicCardSurface()
    }

    /// Guests suggest from songs they already have on this device; the host decides.
    private var suggestMenu: some View {
        let choices = Array((hub.library.recent + hub.library.liked).reduce(into: [MusicTrack]()) { acc, t in
            if !acc.contains(where: { $0.uid == t.uid }) { acc.append(t) }
        }.prefix(30))
        return Menu("Suggest a song") {
            if choices.isEmpty { Text("Play or like some songs first") }
            ForEach(choices, id: \.uid) { t in Button("\(t.title) · \(t.artistLine)") { room.suggest(t) }.atlas("control.music.listeningRoomMusicroompagesuggestmenuButton") }
        }
        .menuStyle(.borderlessButton).fixedSize().disabled(choices.isEmpty)
        .accessibilityLabel("Suggest a song to the host").atlas("control.music.listeningRoomSuggestASongToTheHost")
    }
}
