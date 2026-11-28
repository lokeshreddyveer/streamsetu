import Testing
import Foundation
@testable import REDDY

// Song length against stream length: the gate between a video and its audio twin, the trim of a stream that runs past the song, the
// silent-tail net, the seek bar, and the header rewrite for the fragmented MP4 whose length AVFoundation reads at twice the song.
// Plain data and a virtual clock; nothing opens a network connection or an audio device.

@Suite struct LengthMismatchTests {
    // 4:22 listed, as in the report
    static let listed = 262.0

    @Test func longStreamPrefersTheAudioTwin() {
        #expect(MusicLengthGate.needsTwin(listed: Self.listed, videoDeclared: 522))
        #expect(MusicLengthGate.choose(listed: Self.listed, videoDeclared: 522, twinDeclared: 261.5) == .useTwin)
    }

    @Test func noTwinKeepsTheVideo() {
        #expect(MusicLengthGate.choose(listed: Self.listed, videoDeclared: 522, twinDeclared: nil) == .keepVideo)
        // a twin that is itself the wrong length is no better
        #expect(MusicLengthGate.choose(listed: Self.listed, videoDeclared: 522, twinDeclared: 600) == .keepVideo)
    }

    @Test func slightlyLongerStreamIsAccepted() {
        #expect(MusicStreamLength.fit(listed: Self.listed, declared: 270) == .ok)       // 4:30 against 4:22
        #expect(!MusicLengthGate.needsTwin(listed: Self.listed, videoDeclared: 270))
        #expect(MusicStreamLength.fit(listed: Self.listed, declared: Self.listed + 31.4) == .ok)   // 12 percent
        #expect(MusicStreamLength.fit(listed: Self.listed, declared: Self.listed + 32) == .tooLong)
        #expect(MusicStreamLength.fit(listed: 60, declared: 74) == .ok)                  // 15 s floor
    }

    @Test func previewIsRejected() {
        #expect(MusicStreamLength.fit(listed: Self.listed, declared: 30) == .tooShort)
        #expect(MusicLengthGate.needsTwin(listed: Self.listed, videoDeclared: 30))
    }

    @Test func tracksWithoutCatalogueLengthAreUntouched() {
        #expect(MusicStreamLength.fit(listed: 0, declared: 522) == .ok)
        #expect(MusicStreamLength.fit(listed: Self.listed, declared: nil) == .ok)
        var trim = MusicLengthTrim()
        let shown = trim.adopt(listed: 0, reported: 522, declared: nil)
        let ends = trim.shouldEnd(position: 10_000)
        #expect(shown == 522); #expect(!ends)
    }

    @Test func declaredLengthComesFromTheAddress() {
        #expect(MusicStreamLength.declaredSeconds(url: "https://rr1.googlevideo.com/videoplayback?itag=140&dur=261.549&c=VISIONOS") == 261.549)
        #expect(MusicStreamLength.declaredSeconds(url: "https://example.com/a.m4a") == nil)
        #expect(MusicStreamLength.declaredSeconds(of: MusicStream(url: "https://x/y?dur=bad", codec: "aac", container: "m4a")) == nil)
    }

    // MARK: trim

    @Test func playerThatReportsDoubleShowsTheListedLengthAndEndsJustAfter() {
        var trim = MusicLengthTrim()
        let shown = trim.adopt(listed: 262, reported: 523.1, declared: 261.5)
        #expect(shown == 262)                                          // the panel says 4:22, not 8:43
        #expect(trim.plan?.playerMisreads == true)                     // the stream is right, the player's length is not: no swap
        #expect(trim.plan?.endAt == 267)                               // 4:27: listed + min(5 s, 2 percent)
        let early = trim.shouldEnd(position: 266.9)
        let atEnd = trim.shouldEnd(position: 267)
        let twice = trim.shouldEnd(position: 268)                      // once
        #expect(!early); #expect(atEnd); #expect(!twice)
    }

    @Test func aDifferentCutIsTrimmedToo() {
        var trim = MusicLengthTrim()
        let shown = trim.adopt(listed: 262, reported: 522, declared: 522)
        #expect(shown == 262)
        #expect(trim.plan?.differentCut == true)
        #expect(trim.plan?.endAt == 267)
    }

    @Test func endToleranceIsSmallerOfFiveSecondsAndTwoPercent() {
        #expect(MusicStreamLength.endTolerance(listed: 262) == 5)
        #expect(MusicStreamLength.endTolerance(listed: 100) == 2)
        #expect(MusicStreamLength.endTolerance(listed: 1000) == 5)
    }

    @Test func accurateOrSlightlyOffLengthIsTheStreamsOwn() {
        var trim = MusicLengthTrim()
        let shown = trim.adopt(listed: 262, reported: 270, declared: 270)
        #expect(shown == 270)
        #expect(trim.plan?.endAt == nil)
    }

    @Test func shorterStreamKeepsTheListedLengthWithoutAnEarlyEnd() {
        var trim = MusicLengthTrim()
        let shown = trim.adopt(listed: 262, reported: 30, declared: 30)
        #expect(shown == 262)
        #expect(trim.plan?.endAt == nil)                               // the file ends itself
    }

    @Test func playerLengthShownEqualsListedWhenTrimmed() {
        var trim = MusicLengthTrim()
        for reported in [523.1, 400.0, 300.5] { let shown = trim.adopt(listed: 262, reported: reported, declared: 261.5); #expect(shown == 262) }
    }

    // MARK: seek bar

    @Test func seekBarMapsToTheListedLength() {
        let shown = 262.0
        #expect(MusicStreamLength.seekTarget(fraction: 1, shown: shown) == 262)
        #expect(MusicStreamLength.seekTarget(fraction: 0.5, shown: shown) == 131)
        #expect(MusicStreamLength.seekTarget(fraction: 1.4, shown: shown) == 262)
        #expect(MusicStreamLength.fraction(position: 131, shown: shown) == 0.5)
        #expect(MusicStreamLength.fraction(position: 300, shown: shown) == 1)
        #expect(MusicStreamLength.fraction(position: 5, shown: 0) == 0)
    }

    // MARK: silent tail (virtual clock)

    @Test func silentTailAdvancesAfterEightSecondsPastTheListedLength() {
        var tail = MusicSilentTail(listed: 262, declared: 522)
        var fired: Double?
        var t = 250.0
        while t < 400, fired == nil {
            let level: Float = t < 262 ? 0.3 : 0                       // sound stops at the listed length
            if tail.feed(position: t, level: level) { fired = t }
            t += 0.25
        }
        #expect(fired != nil)
        #expect(fired! > 270 && fired! <= 270.5)                       // 262 + just over 8 s
    }

    @Test func silentTailNeedsTwelveSecondsLateInASongWhoseStreamIsLonger() {
        var tail = MusicSilentTail(listed: 262, declared: 522)
        var fired: Double?
        var t = 215.0                                                   // past 80 percent
        while t < 300, fired == nil { if tail.feed(position: t, level: 0) { fired = t }; t += 0.25 }
        #expect(fired != nil && fired! > 227 && fired! <= 227.5)
    }

    @Test func silentTailIgnoresQuietPassagesAndMissingMeters() {
        var tail = MusicSilentTail(listed: 262, declared: 261.5)
        var any = false
        for i in 0..<400 { if tail.feed(position: 100 + Double(i) * 0.25, level: 0) { any = true } }
        #expect(!any)   // a long quiet part mid-song with equal lengths
        var noMeter = MusicSilentTail(listed: 262, declared: 522)
        let noMeterFired = noMeter.feed(position: 300, level: nil)
        #expect(!noMeterFired)
        var sound = MusicSilentTail(listed: 262, declared: 522)
        _ = sound.feed(position: 263, level: 0)
        let resumed = sound.feed(position: 275, level: 0.2)             // sound again resets
        let after = sound.feed(position: 280, level: 0)
        #expect(!resumed); #expect(!after)
    }

    // MARK: late swap (existing gate; direct tracks use it too)

    @Test func lateSwapHappensOncePerRow() {
        var gate = MusicLateSwapGate()
        let row = UUID()
        let first = gate.allow(uid: "ytmusic:A_RV2H2F9jw", row: row)
        let again = gate.allow(uid: "ytmusic:A_RV2H2F9jw", row: row)
        let nextRow = gate.allow(uid: "ytmusic:A_RV2H2F9jw", row: UUID())
        #expect(first); #expect(!again); #expect(nextRow)
    }

    // MARK: downloads and the cache keep the good version

    @Test func headerRewriteMakesTheStoredFileMeasureRight() {
        var d = Self.fragmentedHeader(mdhdDuration: 0xB00000)
        let before = d.count
        #expect(MusicMP4Header.neutraliseDurations(in: &d, fileOffset: 0))
        #expect(d.count == before)
        #expect(Self.mdhdDuration(d) == 0)
        #expect(!MusicMP4Header.neutraliseDurations(in: &d, fileOffset: 0))   // nothing left to change
    }

    @Test func headerRewriteLeavesOtherFilesAndOffsetsAlone() {
        var plain = Self.fragmentedHeader(mdhdDuration: 0xB00000, fragmented: false)
        #expect(!MusicMP4Header.neutraliseDurations(in: &plain, fileOffset: 0))
        #expect(Self.mdhdDuration(plain) == 0xB00000)
        var later = Self.fragmentedHeader(mdhdDuration: 0xB00000)
        #expect(!MusicMP4Header.neutraliseDurations(in: &later, fileOffset: 4096))
        var cutData = Data(Self.fragmentedHeader(mdhdDuration: 0xB00000).prefix(40))
        #expect(!MusicMP4Header.neutraliseDurations(in: &cutData, fileOffset: 0))
        var junk = Data(repeating: 0xFF, count: 64)
        #expect(!MusicMP4Header.neutraliseDurations(in: &junk, fileOffset: 0))
    }

    // MARK: synthetic fragmented MP4 header

    static func box(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let n = UInt32(body.count + 8)
        return [UInt8(n >> 24 & 255), UInt8(n >> 16 & 255), UInt8(n >> 8 & 255), UInt8(n & 255)] + Array(type.utf8) + body
    }
    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }

    static func fragmentedHeader(mdhdDuration: UInt32, fragmented: Bool = true) -> Data {
        let mvhd = box("mvhd", [0, 0, 0, 0] + be32(0) + be32(0) + be32(44100) + be32(mdhdDuration) + [UInt8](repeating: 0, count: 80))
        let mdhd = box("mdhd", [0, 0, 0, 0] + be32(0) + be32(0) + be32(44100) + be32(mdhdDuration) + [0, 0, 0, 0])
        let trak = box("trak", box("mdia", mdhd))
        var moovBody = mvhd
        if fragmented { moovBody += box("mvex", box("trex", [UInt8](repeating: 0, count: 24))) }
        moovBody += trak
        let file = box("ftyp", Array("dash".utf8) + be32(0) + Array("iso6mp41".utf8)) + box("moov", moovBody) + box("sidx", [UInt8](repeating: 0, count: 40))
        return Data(file)
    }

    static func mdhdDuration(_ d: Data) -> UInt32 {
        let i = d.range(of: Data("mdhd".utf8))!.upperBound
        return d[i + 16..<i + 20].reduce(0) { $0 << 8 | UInt32($1) }
    }
}
