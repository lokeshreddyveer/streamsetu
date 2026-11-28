import SwiftUI

// The decisions behind the Devices and Listen Together pages, as plain values so they are tested: which kind of device a name looks like,
// which state chip and actions a device card gets, how participants are ordered and what their avatar looks like, how the sync state of a
// guest is worded, and which layout a room shows. Nothing here reads a service; the pages pass the real values in.

// MARK: - Device kind

/// The kind of device a card draws. The remote protocol does not carry a device kind, so a found device is classified by its name (the
/// name a Mac, iPhone, iPad or Apple TV gives itself) and falls back to a neutral glyph.
enum MusicDeviceKind: Equatable, Sendable, CaseIterable {
    case mac, iPhone, iPad, tv, speaker, other

    static func infer(name: String) -> MusicDeviceKind {
        let n = name.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { n.contains($0) } }
        if has(["iphone"]) { return .iPhone }
        if has(["ipad"]) { return .iPad }
        if has(["apple tv", "appletv", "android tv", "fire tv", "television"]) || n.split(whereSeparator: { !$0.isLetter }).contains("tv") { return .tv }
        if has(["homepod", "speaker", "sonos", "echo", "soundbar"]) { return .speaker }
        if has(["mac", "imac", "macbook", "studio", "laptop", "desktop"]) { return .mac }
        return .other
    }

    /// The kind of this device, known at compile time.
    static var thisDevice: MusicDeviceKind {
        #if os(macOS)
        .mac
        #else
        .iPhone
        #endif
    }

    var symbol: String {
        switch self {
        case .mac: "laptopcomputer"
        case .iPhone: "iphone"
        case .iPad: "ipad"
        case .tv: "appletv"
        case .speaker: "hifispeaker"
        case .other: "airplayaudio"
        }
    }

    var label: String {
        switch self {
        case .mac: "Mac"
        case .iPhone: "iPhone"
        case .iPad: "iPad"
        case .tv: "TV"
        case .speaker: "Speaker"
        case .other: "Device"
        }
    }
}

// MARK: - Device card state

enum MusicDeviceCardState: Equatable, Sendable, CaseIterable {
    case thisDevice, connected, paired, available, pairing, unreachable

    struct Chip: Equatable, Sendable { var title: String; var symbol: String; var tone: MusicStatusTone }
    enum Action: Hashable, Sendable { case control, pair, cancel, disconnect, forget }
    enum LastSeen: Equatable, Sendable { case now, notInThisSearch, notLookedYet }

    /// - `isThis`: the card is this device. `isConnected`: this device is controlling it right now. `isPaired`: a saved pairing exists.
    /// - `isDiscovered`: it answered in the current search. `searching`: a search is running or has run since the page opened.
    static func resolve(isThis: Bool, isConnected: Bool, isPaired: Bool, isDiscovered: Bool, codeOpen: Bool, searching: Bool) -> MusicDeviceCardState {
        if isThis { return .thisDevice }
        if isConnected { return .connected }
        if isPaired { return isDiscovered || !searching ? .paired : .unreachable }
        return codeOpen ? .pairing : .available
    }

    var chip: Chip {
        switch self {
        case .thisDevice: Chip(title: "This device", symbol: "checkmark.seal.fill", tone: .good)
        case .connected: Chip(title: "Connected", symbol: "checkmark.circle.fill", tone: .good)
        case .paired: Chip(title: "Paired", symbol: "link", tone: .neutral)
        case .available: Chip(title: "Available", symbol: "circle.dashed", tone: .neutral)
        case .pairing: Chip(title: "Pairing", symbol: "number.circle", tone: .neutral)
        case .unreachable: Chip(title: "Unreachable", symbol: "exclamationmark.triangle.fill", tone: .warning)
        }
    }

    /// The buttons of a card, the main one first.
    var actions: [Action] {
        switch self {
        case .thisDevice: []
        case .connected: [.disconnect]
        case .paired: [.control, .forget]
        case .available: [.pair]
        case .pairing: [.cancel]
        case .unreachable: [.forget]
        }
    }

    /// Cards sort by how useful they are right now: the one in use, then ready ones, then new ones, then those that did not answer.
    var sortRank: Int {
        switch self {
        case .thisDevice: 0
        case .connected: 1
        case .paired: 2
        case .pairing: 3
        case .available: 4
        case .unreachable: 5
        }
    }

    static func actionTitle(_ a: Action) -> String {
        switch a { case .control: "Control"; case .pair: "Pair"; case .cancel: "Cancel"; case .disconnect: "Disconnect"; case .forget: "Forget" }
    }
}

/// One entry of the "other devices" list before it is drawn.
struct MusicDeviceEntry: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var state: MusicDeviceCardState
    var pairedAt: Date?
    /// It answered in the current search.
    var discovered: Bool
    var kind: MusicDeviceKind { MusicDeviceKind.infer(name: name) }
    /// The buttons of the card. A saved device that has not answered cannot be controlled, because there is no address to reach it at.
    var actions: [MusicDeviceCardState.Action] { state.actions.filter { discovered || $0 != .control } }
    /// What is honestly known about when it was seen: only a live search tells; there is no stored "last seen".
    var lastSeen: MusicDeviceCardState.LastSeen {
        if discovered { return .now }
        return state == .unreachable ? .notInThisSearch : .notLookedYet
    }
}

enum MusicDeviceList {
    /// Found devices and saved pairings as one list: a device that is both found and paired appears once; a saved pairing that did not answer
    /// stays in the list so it can be forgotten. Sorted by state, then by name.
    static func entries(peers: [(id: String, name: String)], paired: [(id: String, name: String, at: Date)], connectedID: String?, codeOpenID: String?, searching: Bool) -> [MusicDeviceEntry] {
        var out: [MusicDeviceEntry] = []
        let pairedByID = Dictionary(paired.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for p in peers {
            let rec = pairedByID[p.id]
            let state = MusicDeviceCardState.resolve(isThis: false, isConnected: connectedID == p.id, isPaired: rec != nil, isDiscovered: true,
                                                     codeOpen: codeOpenID == p.id, searching: searching)
            out.append(MusicDeviceEntry(id: p.id, name: p.name, state: state, pairedAt: rec?.at, discovered: true))
        }
        let seen = Set(peers.map(\.id))
        for r in paired where !seen.contains(r.id) {
            let state = MusicDeviceCardState.resolve(isThis: false, isConnected: connectedID == r.id, isPaired: true, isDiscovered: false,
                                                     codeOpen: false, searching: searching)
            out.append(MusicDeviceEntry(id: r.id, name: r.name.isEmpty ? "Unnamed device" : r.name, state: state, pairedAt: r.at, discovered: false))
        }
        return out.sorted {
            if $0.state.sortRank != $1.state.sortRank { return $0.state.sortRank < $1.state.sortRank }
            let c = $0.name.localizedCaseInsensitiveCompare($1.name)
            return c == .orderedSame ? $0.id < $1.id : c == .orderedAscending
        }
    }
}

/// What the "other devices" area shows.
enum MusicDeviceDiscoveryView: Equatable, Sendable {
    /// Nothing found, nothing saved, no search yet: invite the person to look.
    case invite
    /// Searching with nothing found: a spinner and what to check.
    case searchingEmpty
    /// Searched, stopped, found nothing and nothing is saved.
    case none
    /// There are cards to show.
    case list

    static func decide(browsing: Bool, searchedOnce: Bool, entryCount: Int) -> MusicDeviceDiscoveryView {
        if entryCount > 0 { return .list }
        if browsing { return .searchingEmpty }
        return searchedOnce ? .none : .invite
    }
}

// MARK: - Output device line

enum MusicOutputLine {
    /// The words under the output name: why this output is the one in use.
    static func detail(_ r: MusicOutputDevicePolicy.Resolution, chosenName: String?) -> String {
        let name = chosenName ?? Localized.string("The chosen device")
        switch r {
        case .systemDefault: return Localized.string("Follows the system output.")
        case .device: return Localized.string("Chosen for Music.")
        case .yieldedMissing: return Localized.string("%@ is not connected, so the system output is used.", name)
        case .yieldedFailed: return Localized.string("%@ would not open, so the system output is used.", name)
        }
    }

    static func needsAttention(_ r: MusicOutputDevicePolicy.Resolution) -> Bool {
        switch r { case .yieldedMissing, .yieldedFailed: true; default: false }
    }
}

// MARK: - Avatars

enum MusicAvatarLogic {
    /// One or two capital letters: the first letters of the first two words. A name with no letters gives a question mark.
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" || $0 == "." }).filter { $0.first(where: \.isLetter) != nil || $0.first?.isNumber == true }
        let letters = words.prefix(2).compactMap { $0.first(where: { $0.isLetter || $0.isNumber }) }
        guard !letters.isEmpty else { return "?" }
        return String(letters).uppercased()
    }

    /// A stable hue in 0..<1 for a name: the same name always gets the same colour, on every launch (it does not use Swift's seeded hashing).
    static func hue(_ name: String) -> Double {
        var h: UInt64 = 0xcbf29ce484222325
        for b in name.lowercased().utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return Double(h % 360) / 360
    }
}

// MARK: - Room

struct MusicRoomPerson: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var isHost: Bool
    /// True for this device's own entry.
    var isYou: Bool
}

enum MusicRoomOrdering {
    /// The host first, this device next (when it is a guest), then everyone else by name, then by id so the order never flickers.
    static func ordered(_ participants: [MusicRoomParticipant], selfName: String?) -> [MusicRoomPerson] {
        let people = participants.map { MusicRoomPerson(id: $0.id, name: $0.name, isHost: $0.isHost, isYou: !$0.isHost && selfName != nil && $0.name == selfName) }
        return people.sorted {
            if $0.isHost != $1.isHost { return $0.isHost }
            if $0.isYou != $1.isYou { return $0.isYou }
            let c = $0.name.localizedCaseInsensitiveCompare($1.name)
            return c == .orderedSame ? $0.id < $1.id : c == .orderedAscending
        }
    }
}

/// How well this device is keeping in step with the host, from what the session really reports.
enum MusicSyncState: Equatable, Sendable {
    case measuring, inSync, adjusting, noSource, nothingPlaying, hostLost

    static func resolve(status: MusicRoomSession.Status, hasClock: Bool, adjusting: Bool, hasSourceProblem: Bool, hasTrack: Bool) -> MusicSyncState? {
        switch status {
        case .hostConnectionLost: return .hostLost
        case .joined: break
        default: return nil
        }
        if hasSourceProblem { return .noSource }
        if !hasTrack { return .nothingPlaying }
        if !hasClock { return .measuring }
        return adjusting ? .adjusting : .inSync
    }

    var chip: MusicDeviceCardState.Chip {
        switch self {
        case .measuring: .init(title: "Measuring", symbol: "waveform.path", tone: .neutral)
        case .inSync: .init(title: "In sync", symbol: "checkmark.circle.fill", tone: .good)
        case .adjusting: .init(title: "Resyncing", symbol: "arrow.triangle.2.circlepath", tone: .warning)
        case .noSource: .init(title: "Not playing here", symbol: "speaker.slash.fill", tone: .warning)
        case .nothingPlaying: .init(title: "Waiting for a song", symbol: "pause.circle", tone: .neutral)
        case .hostLost: .init(title: "Lost contact", symbol: "wifi.exclamationmark", tone: .bad)
        }
    }

    var explanation: String {
        switch self {
        case .measuring: "Measuring the delay to the host."
        case .inSync: "Playing at the same moment as the host."
        case .adjusting: "A little off the host, closing the gap by playing slightly faster or slower."
        case .noSource: "This device cannot play the current song. The room keeps going without it."
        case .nothingPlaying: "The host has not started a song."
        case .hostLost: "Lost contact with the host. Your song keeps playing for a short while."
        }
    }

    /// The measured network round trip in whole milliseconds, only when the session has measured one.
    static func roundTripMillis(_ sample: MusicRoomClockSample?) -> Int? {
        guard let s = sample, s.rtt.isFinite else { return nil }
        return Int((s.rtt * 1000).rounded())
    }
}

/// Which layout the room page draws.
enum MusicRoomLayout: Equatable, Sendable {
    /// No room: start one or look for one.
    case idle
    /// Hosting and nobody has joined yet.
    case hostWaiting
    /// Hosting with at least one guest.
    case hostActive
    /// Joining: connecting or waiting for the host to approve.
    case joining
    /// In a room as a guest.
    case listening
    /// In a room as a guest and the host went quiet.
    case hostLost

    static func decide(role: MusicRoomSession.Role, status: MusicRoomSession.Status, hostOpen: Bool, guestCount: Int, pendingCount: Int) -> MusicRoomLayout {
        switch role {
        case .none: return .idle
        case .host: return hostOpen && (guestCount > 0 || pendingCount > 0) ? .hostActive : .hostWaiting
        case .guest:
            switch status {
            case .joined: return .listening
            case .hostConnectionLost: return .hostLost
            default: return .joining
            }
        }
    }

    var isHosting: Bool { self == .hostWaiting || self == .hostActive }
    var isFollowing: Bool { self == .listening || self == .hostLost }
}

enum MusicRoomInvite {
    /// The text a share sheet or the clipboard carries. The code works once and for a short time; the text says so.
    static func text(roomName: String, code: String) -> String {
        Localized.string("Join my room \"%1$@\" in StreamSetu Music. On the same Wi-Fi, open Listen Together, look for rooms and enter the code %2$@. The code works for a short time.", roomName, code)
    }

    /// The host's own queue as the room shows it: the song playing and what follows, read-only.
    static func upNext(_ window: [String], limit: Int) -> [String] { Array(window.dropFirst().prefix(max(0, limit))) }
}
