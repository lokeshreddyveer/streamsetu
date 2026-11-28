import Testing
import SwiftUI
@testable import REDDY

// Pure logic of the redesigned Devices and Listen Together pages: device kind, state chips and actions, list building, avatars,
// participant order, sync-state wording and the room layout decision.

@MainActor
struct DevicesRoomTests {
    // MARK: device kind

    @Test func kindIsInferredFromTheDeviceName() {
        #expect(MusicDeviceKind.infer(name: "Asha's iPhone") == .iPhone)
        #expect(MusicDeviceKind.infer(name: "Living Room iPad") == .iPad)
        #expect(MusicDeviceKind.infer(name: "Bedroom Apple TV") == .tv)
        #expect(MusicDeviceKind.infer(name: "Kitchen HomePod") == .speaker)
        #expect(MusicDeviceKind.infer(name: "MacBook-Pro") == .mac)
        #expect(MusicDeviceKind.infer(name: "Raspberry") == .other)
        #expect(Set(MusicDeviceKind.allCases.map(\.symbol)).count == MusicDeviceKind.allCases.count)
    }

    // MARK: state to chip and actions

    @Test func stateResolutionOrder() {
        func r(this: Bool = false, conn: Bool = false, paired: Bool = false, found: Bool = true, code: Bool = false, searching: Bool = true) -> MusicDeviceCardState {
            .resolve(isThis: this, isConnected: conn, isPaired: paired, isDiscovered: found, codeOpen: code, searching: searching)
        }
        #expect(r(this: true, conn: true) == .thisDevice)
        #expect(r(conn: true, paired: true) == .connected)
        #expect(r(paired: true) == .paired)
        #expect(r(paired: true, found: false) == .unreachable)
        #expect(r(paired: true, found: false, searching: false) == .paired)
        #expect(r() == .available)
        #expect(r(code: true) == .pairing)
    }

    @Test func chipsCarryWordAndSymbolForEveryState() {
        let titles = MusicDeviceCardState.allCases.map(\.chip.title)
        #expect(Set(titles).count == titles.count)
        #expect(MusicDeviceCardState.thisDevice.chip.title == "This device")
        #expect(MusicDeviceCardState.connected.chip.tone == .good)
        #expect(MusicDeviceCardState.unreachable.chip.tone == .warning)
        for s in MusicDeviceCardState.allCases { #expect(!s.chip.symbol.isEmpty) }
    }

    @Test func actionsPerState() {
        #expect(MusicDeviceCardState.paired.actions == [.control, .forget])
        #expect(MusicDeviceCardState.available.actions == [.pair])
        #expect(MusicDeviceCardState.connected.actions == [.disconnect])
        #expect(MusicDeviceCardState.unreachable.actions == [.forget])
        #expect(MusicDeviceCardState.thisDevice.actions.isEmpty)
        #expect(MusicDeviceCardState.actionTitle(.control) == "Control")
    }

    // MARK: list

    @Test func listMergesFoundAndSavedAndSortsByUsefulness() {
        let now = Date(timeIntervalSince1970: 1_000)
        let list = MusicDeviceList.entries(
            peers: [(id: "b", name: "Zed iPad"), (id: "a", name: "Amy iPhone"), (id: "c", name: "New Mac")],
            paired: [(id: "a", name: "Amy iPhone", at: now), (id: "gone", name: "Old TV", at: now)],
            connectedID: "b", codeOpenID: nil, searching: true)
        #expect(list.map(\.id) == ["b", "a", "c", "gone"])
        #expect(list.map(\.state) == [.connected, .paired, .available, .unreachable])
        #expect(list.filter { $0.id == "a" }.count == 1)
        #expect(list[3].lastSeen == .notInThisSearch)
        #expect(list[0].lastSeen == .now)
        #expect(!list[3].actions.contains(.control))
    }

    @Test func savedDeviceBeforeASearchIsPairedButNotControllable() {
        let list = MusicDeviceList.entries(peers: [], paired: [(id: "x", name: "", at: Date())], connectedID: nil, codeOpenID: nil, searching: false)
        #expect(list.count == 1)
        #expect(list[0].state == .paired)
        #expect(list[0].lastSeen == .notLookedYet)
        #expect(list[0].actions == [.forget])
    }

    @Test func discoveryViewDecision() {
        #expect(MusicDeviceDiscoveryView.decide(browsing: false, searchedOnce: false, entryCount: 0) == .invite)
        #expect(MusicDeviceDiscoveryView.decide(browsing: true, searchedOnce: true, entryCount: 0) == .searchingEmpty)
        #expect(MusicDeviceDiscoveryView.decide(browsing: false, searchedOnce: true, entryCount: 0) == .none)
        #expect(MusicDeviceDiscoveryView.decide(browsing: true, searchedOnce: true, entryCount: 2) == .list)
    }

    @Test func outputLineNeedsAttentionOnlyWhenTheChoiceYielded() {
        #expect(!MusicOutputLine.needsAttention(.systemDefault))
        #expect(!MusicOutputLine.needsAttention(.device("x")))
        #expect(MusicOutputLine.needsAttention(.yieldedMissing("x")))
        #expect(MusicOutputLine.needsAttention(.yieldedFailed("x")))
    }

    // MARK: avatars

    @Test func initialsUseTheFirstLettersOfTwoWords() {
        #expect(MusicAvatarLogic.initials("Asha Rao") == "AR")
        #expect(MusicAvatarLogic.initials("lokesh") == "L")
        #expect(MusicAvatarLogic.initials("Living-Room iPad extra") == "LR")
        #expect(MusicAvatarLogic.initials("") == "?")
        #expect(MusicAvatarLogic.initials("  ...  ") == "?")
        #expect(MusicAvatarLogic.initials("అమ్మ ఇల్లు").count >= 1)
    }

    @Test func hueIsStableAndInRange() {
        #expect(MusicAvatarLogic.hue("Asha") == MusicAvatarLogic.hue("Asha"))
        #expect(MusicAvatarLogic.hue("Asha") == MusicAvatarLogic.hue("asha"))
        #expect(MusicAvatarLogic.hue("Asha") != MusicAvatarLogic.hue("Ravi"))
        for n in ["a", "Ravi", "", "Mac mini"] { let h = MusicAvatarLogic.hue(n); #expect(h >= 0 && h < 1) }
        // A fixed value, so a change of the hashing is noticed (it would recolour every avatar).
        #expect(MusicAvatarLogic.hue("Asha") == 266.0 / 360)
    }

    // MARK: participants

    @Test func hostFirstThenYouThenByName() {
        let roster = [MusicRoomParticipant(id: "3", name: "zoe", isHost: false), MusicRoomParticipant(id: "2", name: "Ben", isHost: false),
                      MusicRoomParticipant(id: "1", name: "Studio Mac", isHost: true), MusicRoomParticipant(id: "4", name: "Me", isHost: false)]
        let ordered = MusicRoomOrdering.ordered(roster, selfName: "Me")
        #expect(ordered.map(\.id) == ["1", "4", "2", "3"])
        #expect(ordered[1].isYou)
        #expect(!ordered[0].isYou)
        #expect(MusicRoomOrdering.ordered(roster.reversed(), selfName: "Me").map(\.id) == ordered.map(\.id))
    }

    @Test func sameNamesKeepAStableOrderById() {
        let roster = [MusicRoomParticipant(id: "b", name: "Pat", isHost: false), MusicRoomParticipant(id: "a", name: "Pat", isHost: false)]
        #expect(MusicRoomOrdering.ordered(roster, selfName: nil).map(\.id) == ["a", "b"])
    }

    // MARK: sync

    @Test func syncStateFromWhatTheSessionReports() {
        func s(_ status: MusicRoomSession.Status, clock: Bool = true, adj: Bool = false, problem: Bool = false, track: Bool = true) -> MusicSyncState? {
            MusicSyncState.resolve(status: status, hasClock: clock, adjusting: adj, hasSourceProblem: problem, hasTrack: track)
        }
        #expect(s(.joined) == .inSync)
        #expect(s(.joined, adj: true) == .adjusting)
        #expect(s(.joined, clock: false) == .measuring)
        #expect(s(.joined, problem: true) == .noSource)
        #expect(s(.joined, track: false) == .nothingPlaying)
        #expect(s(.hostConnectionLost) == .hostLost)
        #expect(s(.connecting) == nil)
        #expect(s(.hosting) == nil)
        #expect(s(.idle) == nil)
    }

    @Test func roundTripIsShownOnlyWhenMeasured() {
        #expect(MusicSyncState.roundTripMillis(nil) == nil)
        #expect(MusicSyncState.roundTripMillis(MusicRoomClockSample(offset: 3, rtt: 0.0124)) == 12)
        #expect(MusicSyncState.roundTripMillis(MusicRoomClockSample(offset: 0, rtt: .infinity)) == nil)
        for st in [MusicSyncState.measuring, .inSync, .adjusting, .noSource, .nothingPlaying, .hostLost] { #expect(!st.explanation.isEmpty && !st.chip.title.isEmpty) }
    }

    // MARK: layout

    @Test func roomLayoutDecision() {
        func d(_ role: MusicRoomSession.Role, _ status: MusicRoomSession.Status, open: Bool = true, guests: Int = 0, pending: Int = 0) -> MusicRoomLayout {
            .decide(role: role, status: status, hostOpen: open, guestCount: guests, pendingCount: pending)
        }
        #expect(d(.none, .idle) == .idle)
        #expect(d(.none, .ended("x")) == .idle)
        #expect(d(.host, .hosting) == .hostWaiting)
        #expect(d(.host, .hosting, open: false, guests: 2) == .hostWaiting)
        #expect(d(.host, .hosting, guests: 1) == .hostActive)
        #expect(d(.host, .hosting, pending: 1) == .hostActive)
        #expect(d(.guest, .connecting) == .joining)
        #expect(d(.guest, .waitingForApproval) == .joining)
        #expect(d(.guest, .joined) == .listening)
        #expect(d(.guest, .hostConnectionLost) == .hostLost)
        #expect(MusicRoomLayout.hostActive.isHosting && MusicRoomLayout.listening.isFollowing && !MusicRoomLayout.joining.isFollowing)
    }

    @Test func upNextSkipsTheCurrentSongAndHonoursTheLimit() {
        #expect(MusicRoomInvite.upNext(["a", "b", "c", "d"], limit: 2) == ["b", "c"])
        #expect(MusicRoomInvite.upNext([], limit: 5).isEmpty)
        #expect(MusicRoomInvite.upNext(["a"], limit: 5).isEmpty)
    }
}
