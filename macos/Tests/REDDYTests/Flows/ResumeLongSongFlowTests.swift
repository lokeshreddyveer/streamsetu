import Testing
import Foundation
@testable import REDDY

/// A long recording (a mix, a lecture, a concert) remembers where it was left, and playing it again carries on from there. The start was computed and
/// shown ("Resuming at 30:00") yet playback began at 0:00, and 15 seconds later the saved place was overwritten. These flows drive the real hub and player.
@MainActor
@Suite("Flow: resume a long song at its saved place", .serialized)
struct ResumeLongSongFlowTests {
    private func makeRig() throws -> FlowRig {
        // The "remember my place" length is a plain UserDefaults value (default 10 minutes); start from the default whatever the Mac has set.
        UserDefaults.standard.removeObject(forKey: MusicSeekPrefs.resumeKey)
        MusicPrivateListening.shared.isOn = false
        return try FlowRig()
    }

    private func longSong() -> MusicTrack { FlowRig.songs(1, minutes: 120, prefix: "long")[0] }

    @Test func aLongSongStartsWhereItWasLeft() throws {
        let rig = try makeRig(); defer { rig.cleanup() }
        let t = longSong()
        rig.hub.library.rememberResume(t, position: 1_800, duration: t.duration)
        #expect(rig.hub.library.resumePosition(for: t, duration: t.duration) == 1_800)

        rig.hub.play([t], at: 0)

        #expect(rig.player.current?.uid == t.uid)
        #expect(rig.player.position == 1_800, "the bar and the load must start at the saved place, not 0:00")
    }

    @Test func aShortSongNeverResumes() throws {
        let rig = try makeRig(); defer { rig.cleanup() }
        let t = FlowRig.songs(1, minutes: 4)[0]
        rig.hub.library.rememberResume(t, position: 120, duration: t.duration)
        #expect(rig.hub.library.resumePosition(for: t, duration: t.duration) == nil)
        rig.hub.play([t], at: 0)
        #expect(rig.player.position == 0)
    }

    @Test func aPlaceInTheLastSecondsCountsAsFinished() throws {
        let rig = try makeRig(); defer { rig.cleanup() }
        let t = longSong()
        rig.hub.library.rememberResume(t, position: t.duration - 5, duration: t.duration)
        rig.hub.play([t], at: 0)
        #expect(rig.player.position == 0)
    }

    @Test func privateListeningDoesNotResume() throws {
        let rig = try makeRig(); defer { rig.cleanup(); MusicPrivateListening.shared.isOn = false }
        let t = longSong()
        rig.hub.library.rememberResume(t, position: 900, duration: t.duration)
        MusicPrivateListening.shared.isOn = true
        rig.hub.play([t], at: 0)
        #expect(rig.player.position == 0)
    }

    @Test func aSeekMadeWhileTheSongIsStillResolvingIsKept() throws {
        let rig = try makeRig(); defer { rig.cleanup() }
        let t = longSong()
        rig.hub.play([t], at: 0)
        rig.player.seek(to: 600)
        #expect(rig.player.position == 600, "the scrubber position must stay where the person put it until the song is installed")
    }

    @Test func theSavedPlaceSurvivesTheStartAndALaterFailedLoad() async throws {
        let rig = try makeRig(); defer { rig.cleanup() }
        let t = longSong()
        rig.hub.library.rememberResume(t, position: 2_400, duration: t.duration)
        rig.hub.play([t], at: 0)
        // Every source is off, so the load fails in the background; the saved place must not be replaced by a start at 0.
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(rig.hub.library.resumePosition(for: t, duration: t.duration) == 2_400)
    }

    /// The load installs the song at `position`, the one place that holds the start, a custom start and a seek made meanwhile (a stale argument was
    /// passed before, so the resume was computed and then ignored). This reads the player source because the install itself needs real audio.
    @Test func theLoadInstallsTheSongAtTheKeptPosition() throws {
        let file = try #require(GuardScanner.files(under: ["Services/Music/Playback"]).first { $0.path.hasSuffix("MusicPlayer.swift") })
        let code = file.code
        let start = try #require(code.range(of: "private func load(_ entry: MusicQueue.Entry, gen: Int) async {"))
        let tail = String(code[start.upperBound...])
        let end = tail.range(of: "\n    private func makeLoaded")?.lowerBound ?? tail.endIndex
        let body = String(tail[..<end])
        #expect(body.contains("install(loaded, resumeAt: position)"))
        #expect(!body.contains("resumeAt: resumeAt"))
    }
}
