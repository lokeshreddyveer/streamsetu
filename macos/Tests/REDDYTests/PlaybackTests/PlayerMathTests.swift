import Testing
import Foundation
@testable import REDDY

@Suite struct PlayerMathTests {
    @Test func wideFilmsAreNamedByTheirWidth() {
        #expect(PlayerMath.qualityLabel(width: 1920, height: 804) == "1080p")
        #expect(PlayerMath.qualityLabel(width: 3840, height: 2160) == "4K")
        #expect(PlayerMath.qualityLabel(width: 3840, height: 1600) == "4K")
        #expect(PlayerMath.qualityLabel(width: 1280, height: 720) == "720p")
        #expect(PlayerMath.qualityLabel(width: 854, height: 480) == "480p")
        #expect(PlayerMath.qualityLabel(width: 640, height: 360) == "360p")
    }

    @Test func aSwipeMovesInProportionAndStaysInsideTheFile() {
        #expect(PlayerMath.scrubTarget(position: 600, dragPoints: 200, screenWidth: 400, duration: 7200) == 720)
        #expect(PlayerMath.scrubTarget(position: 600, dragPoints: -100, screenWidth: 400, duration: 7200) == 540)
        #expect(PlayerMath.scrubTarget(position: 30, dragPoints: -400, screenWidth: 400, duration: 7200) == 0)
        #expect(PlayerMath.scrubTarget(position: 7190, dragPoints: 400, screenWidth: 400, duration: 7200) == 7199)
        #expect(PlayerMath.scrubTarget(position: 50, dragPoints: 100, screenWidth: 0, duration: 7200) == 50)
    }

    @Test func repeatedDoubleTapsOnOneSideAddUp() {
        let t0 = Date()
        let first = PlayerMath.stackedSkip(previousTotal: 0, previousSide: 0, previousAt: nil, side: 1, now: t0)
        #expect(first == 10)
        let second = PlayerMath.stackedSkip(previousTotal: first, previousSide: 1, previousAt: t0, side: 1, now: t0.addingTimeInterval(0.6))
        #expect(second == 20)
        #expect(PlayerMath.stackedSkip(previousTotal: second, previousSide: 1, previousAt: t0, side: -1, now: t0.addingTimeInterval(0.8)) == 10)
        #expect(PlayerMath.stackedSkip(previousTotal: second, previousSide: 1, previousAt: t0, side: 1, now: t0.addingTimeInterval(3)) == 10)
    }

    @Test func aSignedClockShowsTheDirection() {
        #expect(PlayerMath.signedClock(80) == "+1:20")
        #expect(PlayerMath.signedClock(-45) == "−0:45")
    }
}

@Suite struct PlayerLabelTests {
    @Test func longVideoDescriptionsBecomeShortNames() {
        #expect(PlayerMath.videoCodecLabel("H.264 / AVC / MPEG-4 AVC / MPEG-4 PART 10") == "H.264")
        #expect(PlayerMath.videoCodecLabel("hevc") == "HEVC")
        #expect(PlayerMath.videoCodecLabel("H.265 / HEVC (High Efficiency Video Coding)") == "HEVC")
        #expect(PlayerMath.videoCodecLabel("mpeg2video") == "MPEG-2")
        #expect(PlayerMath.videoCodecLabel("h264") == "H.264")
    }

    @Test func soundFormatsAreNamedPlainly() {
        #expect(PlayerMath.audioCodecLabel("ac3") == "AC-3")
        #expect(PlayerMath.audioCodecLabel("eac3") == "E-AC-3")
        #expect(PlayerMath.audioCodecLabel("aac") == "AAC")
        #expect(PlayerMath.audioCodecLabel("mp2") == "MP2")
    }

    @Test func aTrackCalledTrackOneSaysNothing() {
        for l in ["Track 1", "track 2", "Audio 1", "Stream 3", "1", "", "Subtitle 2"] { #expect(PlayerMath.isGenericTrackLabel(l)) }
        for l in ["English", "Hindi 5.1", "Commentary", "Spanish (Latin America)"] { #expect(!PlayerMath.isGenericTrackLabel(l)) }
    }
}
