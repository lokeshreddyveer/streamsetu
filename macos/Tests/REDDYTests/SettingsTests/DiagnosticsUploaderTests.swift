import Testing
import Foundation
@testable import REDDY

@Suite struct DiagnosticsUploaderTests {
    @Test func serverNamesBecomeNumberedLabels() {
        let out = LogMasker.mask([
            "start movie live=false http://provider.example:8080 .mp4 container=mp4",
            "mpv: tcp: Connection to tcp://1455251.2957084701.user-one.com:80 failed: Can't assign requested address",
            "relay on for http://provider.example:8080 .ts -> http://127.0.0.1:55783/raw.ts",
            "classify raw error ... failingHost=user-two.com",
            "mpv: Failed to open http://provider.example:8080/movie/***/***/818590.mkv.",
        ])
        #expect(out[0] == "start movie live=false http://server-1:8080 .mp4 container=mp4")
        #expect(out[1].contains("tcp://server-2:80 failed"))
        #expect(out[2] == "relay on for http://server-1:8080 .ts -> http://127.0.0.1:55783/raw.ts")
        #expect(out[3].hasSuffix("failingHost=server-3"))
        #expect(out[4].contains("http://server-1:8080/movie/***/***/818590.mkv"))
        #expect(!out.joined().contains("provider") && !out.joined().contains("user-one") && !out.joined().contains("user-two"))
    }

    @Test func lineWithoutAServerIsLeftAlone() {
        let line = "10-12 13:49:06.117  AVPlayer ready presentationSize=1920x1080 video=avc1 audio=aac"
        #expect(LogMasker.mask([line]) == [line])
        #expect(LogMasker.mask(["failingHost=-"]) == ["failingHost=-"])
    }

    @Test func sharingIsOnUnlessTheyTurnItOff() {
        let d = UserDefaults(suiteName: "diag-test-\(UUID().uuidString)")!
        let u = DiagnosticsUploader(defaults: d)
        #expect(u.isEnabled)
        u.isEnabled = false
        #expect(!u.isEnabled)
        #expect(!DiagnosticsUploader(defaults: d).isEnabled)         // the choice is remembered
        u.isEnabled = true
        #expect(u.isEnabled)
    }

    @Test func theInstallNumberIsRandomAndStaysTheSame() {
        let d = UserDefaults(suiteName: "diag-test-\(UUID().uuidString)")!
        let a = DiagnosticsUploader(defaults: d), b = DiagnosticsUploader(defaults: d)
        #expect(a.installID == b.installID && a.installID.count >= 8)
    }

    @Test func aPayloadNeverCarriesPlaylistNamesOrLogins() {
        let d = UserDefaults(suiteName: "diag-test-\(UUID().uuidString)")!
        let p = DiagnosticsUploader(defaults: d).payload(trigger: "manual", note: "it fails")
        #expect(Set(p.keys) == ["install_id", "trigger", "platform", "app_version", "build", "os_version", "device", "note", "log"])
        #expect(p["note"] as? String == "it fails")
    }

    @Test func automaticReportsAreSpacedOut() {
        let now = Date()
        #expect(DiagnosticsUploader.mayAutoSend(last: nil, now: now))
        #expect(!DiagnosticsUploader.mayAutoSend(last: now.addingTimeInterval(-3600), now: now))
        #expect(DiagnosticsUploader.mayAutoSend(last: now.addingTimeInterval(-4 * 3600), now: now))
    }

    @Test func theFirstLaunchNoticeIsShownOnce() {
        let d = UserDefaults(suiteName: "diag-test-\(UUID().uuidString)")!
        let u = DiagnosticsUploader(defaults: d)
        #expect(!u.noticeShown)
        u.noticeShown = true
        #expect(DiagnosticsUploader(defaults: d).noticeShown)
    }

    @Test func turningItOffStopsAutomaticReports() {
        let d = UserDefaults(suiteName: "diag-test-\(UUID().uuidString)")!
        let u = DiagnosticsUploader(defaults: d)
        u.isEnabled = false
        u.playbackFailed()
        #expect(d.object(forKey: "diagnostics.lastAuto") == nil)      // nothing was sent, so nothing was recorded as sent
    }

    @Test func aTestRunNeverReachesTheRealServerOrTheRealLog() async {
        let before = DiagnosticsUploader.blockedInTests.value
        let sent = await DiagnosticsUploader().send(trigger: "auto")
        #expect(!sent)
        #expect(DiagnosticsUploader.blockedInTests.value == before + 1)
        #expect(PlaybackLog.shared.url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }
}
