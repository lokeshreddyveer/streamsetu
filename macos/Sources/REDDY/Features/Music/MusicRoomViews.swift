import SwiftUI

// Pieces of the Listen Together page: a person card, a request card, the room code with invite actions, a read-only queue and the sync card.
// Each takes plain values; the page passes what the room services really report.

// MARK: - People

/// One person in the room: an avatar, the name, one line of what they are, a state chip, and (for the host) a remove button.
struct MusicPersonCard: View {
    let person: MusicRoomPerson
    /// Set for the host looking at a guest.
    var onRemove: (() -> Void)?

    private var chip: MusicDeviceCardState.Chip {
        if person.isHost { return .init(title: "Host", symbol: "star.fill", tone: .good) }
        if person.isYou { return .init(title: "You", symbol: "person.fill", tone: .neutral) }
        return .init(title: "Connected", symbol: "wifi", tone: .good)
    }

    private var line: String {
        if person.isHost { return Localized.string("Plays the music for everyone") }
        if person.isYou { return Localized.string("Listening on this device") }
        return Localized.string("In the room")
    }

    var body: some View {
        HStack(spacing: MusicSpace.sm) {
            MusicAvatar(name: person.name, size: MusicDeviceMetrics.tile)
            VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                Text(verbatim: person.name).musicText(.card).lineLimit(1).help(Text(verbatim: person.name))
                Text(verbatim: line).musicText(.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MusicStatusChip(title: chip.title, symbol: chip.symbol, tone: chip.tone)
            if let onRemove {
                Button("Remove", action: onRemove).musicButton(.secondary, size: .compact)
                    .accessibilityLabel("Remove \(person.name) from the room").atlas("control.music.listeningRoomRemoveFromTheRoom")
            }
        }
        .padding(MusicSpace.sm).musicCardSurface()
        .accessibilityElement(children: .contain)
    }
}

/// Someone asking to join, or a song a guest suggests: the host answers with two buttons.
struct MusicRequestCard<Buttons: View>: View {
    let name: String
    let title: String
    var detail: String?
    var symbol: String?
    @ViewBuilder var buttons: Buttons

    var body: some View {
        HStack(spacing: MusicSpace.sm) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: MusicIconSize.row)).foregroundStyle(ColorTokens.textSecondary).accessibilityHidden(true)
                    .frame(width: MusicDeviceMetrics.tile, height: MusicDeviceMetrics.tile).background(ColorTokens.card, in: Circle())
            } else {
                MusicAvatar(name: name, size: MusicDeviceMetrics.tile)
            }
            VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                Text(verbatim: title).musicText(.card).lineLimit(2)
                if let detail { Text(verbatim: detail).musicText(.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(2) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            buttons
        }
        .padding(MusicSpace.sm).musicCardSurface()
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Code and invite

/// The room code, large and copyable, with a share sheet and a copy for the invite text.
struct MusicRoomInviteCard: View {
    let roomName: String
    let code: String
    let expires: Date
    let onExpire: () -> Void
    @State private var copiedInvite = false

    private var invite: String { MusicRoomInvite.text(roomName: roomName, code: code) }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            MusicCodeCard(code: code, expires: expires, prompt: "Enter this code on the other device", spokenPrefix: Localized.string("Room code"),
                          timeFormat: "Works for %d more seconds.", copyAtlas: "control.music.listeningRoomCopyCode", onExpire: onExpire)
            HStack(spacing: MusicSpace.xs) {
                ShareLink(item: invite) { Label("Share invite", systemImage: "square.and.arrow.up") }
                    .musicButton(.secondary, size: .compact).atlas("control.music.listeningRoomShareInvite")
                Button { copyInvite() } label: { Label((copiedInvite ? "Copied" : "Copy invite").loc, systemImage: copiedInvite ? "checkmark" : "doc.on.doc") }
                    .musicButton(.tertiary, size: .compact).atlas("control.music.listeningRoomCopyInvite")
                Spacer(minLength: 0)
            }
        }
    }

    private func copyInvite() {
        #if os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(invite, forType: .string)
        #else
        UIPasteboard.general.string = invite
        #endif
        copiedInvite = true
        Task { try? await Task.sleep(for: .seconds(2)); copiedInvite = false }
    }
}

// MARK: - Queue

struct MusicRoomQueueLine: Identifiable, Equatable, Sendable {
    var id: Int
    var title: String
    var artist: String
}

/// The song playing and what follows. Read-only: only the host changes it.
struct MusicRoomQueueCard: View {
    let now: MusicRoomQueueLine?
    var isPlaying = false
    let upNext: [MusicRoomQueueLine]
    let footnote: String

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            if let now {
                HStack(spacing: MusicSpace.sm) {
                    MusicIcon(glyph: isPlaying ? .equalizer : .note, size: MusicIconSize.row, tint: .accent)
                        .frame(width: MusicDeviceMetrics.tile, height: MusicDeviceMetrics.tile)
                    VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                        Text((isPlaying ? "Now playing" : "Paused").loc).musicText(.caption).foregroundStyle(ColorTokens.textSecondary)
                        Text(verbatim: now.title).musicText(.section).lineLimit(2)
                        if !now.artist.isEmpty { Text(verbatim: now.artist).musicText(.body).foregroundStyle(ColorTokens.textSecondary).lineLimit(1) }
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            } else {
                Text("Nothing is playing in the room.").musicText(.body).foregroundStyle(ColorTokens.textSecondary)
            }
            if !upNext.isEmpty {
                Divider().overlay(ColorTokens.line)
                Text("Up next").musicText(.secondary).fontWeight(.semibold).foregroundStyle(ColorTokens.textSecondary)
                ForEach(Array(upNext.enumerated()), id: \.element.id) { i, line in
                    HStack(spacing: MusicSpace.xs) {
                        Text(verbatim: String(i + 1)).font(Typography.timestamp).monospacedDigit().foregroundStyle(ColorTokens.textTertiary)
                            .frame(width: MusicSpace.md, alignment: .trailing)
                        Text(verbatim: line.title).musicText(.secondary).lineLimit(1)
                        if !line.artist.isEmpty { Text(verbatim: line.artist).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary).lineLimit(1) }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Text(footnote.loc).musicText(.caption).foregroundStyle(ColorTokens.textTertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(MusicSpace.sm).frame(maxWidth: .infinity, alignment: .leading).musicCardSurface()
    }
}

// MARK: - Sync

/// How this device keeps in step with the host: a state chip, one plain sentence, and the measured network round trip when there is one.
struct MusicSyncCard: View {
    let state: MusicSyncState
    let roundTripMillis: Int?

    var body: some View {
        let chip = state.chip
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            HStack(spacing: MusicSpace.xs) {
                Text("Sync").musicText(.card)
                Spacer(minLength: MusicSpace.xs)
                MusicStatusChip(title: chip.title, symbol: chip.symbol, tone: chip.tone)
            }
            Text(state.explanation.loc).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary).fixedSize(horizontal: false, vertical: true)
            if let ms = roundTripMillis {
                Text(verbatim: Localized.string("Network round trip to the host: %d ms", ms)).musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
            }
        }
        .padding(MusicSpace.sm).frame(maxWidth: .infinity, alignment: .leading).musicCardSurface()
        .accessibilityElement(children: .combine)
    }
}

/// The room's name, who is in it and a status chip, at the top of an open room.
struct MusicRoomHeaderCard<Trailing: View>: View {
    let name: String
    let detail: String
    let people: [MusicRoomPerson]
    let chip: MusicDeviceCardState.Chip
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: MusicSpace.sm) {
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                Text(verbatim: name).musicText(.section).lineLimit(1)
                Text(verbatim: detail).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary).lineLimit(2)
                MusicAvatarStack(people: people)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: MusicSpace.xs) {
                MusicStatusChip(title: chip.title, symbol: chip.symbol, tone: chip.tone)
                trailing
            }
        }
        .padding(MusicSpace.md).musicCardSurface(corner: MusicCorner.card)
        .accessibilityElement(children: .contain)
    }
}
