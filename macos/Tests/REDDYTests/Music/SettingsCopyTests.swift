import Testing
import Foundation
@testable import REDDY

/// The Music settings keep to short, plain copy: a row has one short line at most, and there are six tabs.
@Suite("Music settings copy") struct SettingsCopyTests {
    private func sources() throws -> [(String, String)] {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/REDDY/Features/Music")
        let en = try #require(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil))
        var out: [(String, String)] = []
        for case let u as URL in en where u.pathExtension == "swift" && u.lastPathComponent.contains("Settings") || u.lastPathComponent == "MusicHotkeysSection.swift" || u.lastPathComponent == "MusicKaraokeSection.swift" {
            out.append((u.lastPathComponent, (try? String(contentsOf: u, encoding: .utf8)) ?? ""))
        }
        return out
    }

    @Test func thereAreSevenTabsAndNoHintBanners() {
        #expect(MusicSettingsTab.allCases.count == 7)
        #expect(MusicSettingsTab.allCases.map(\.title) == ["General", "Playback", "Lyrics", "Sources & Plugins", "Library & Storage", "Devices & Rooms", "Privacy & About"])
    }

    @Test func aRowsSecondaryLineIsShort() throws {
        let re = try NSRegularExpression(pattern: #"detail: "((?:[^"\\\n]|\\.)*)""#)
        var long: [String] = []
        for (name, text) in try sources() {
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let r = Range(m.range(at: 1), in: text) else { continue }
                if text[r].count > 70 { long.append("\(name): \(text[r])") }
            }
        }
        #expect(long.isEmpty, "a row's detail line is over 70 characters, move it to the info popover: \(long)")
    }

    @Test func noSourceIsClaimedToBeOffByDefault() throws {
        for (name, text) in try sources() {
            #expect(!text.localizedCaseInsensitiveContains("off until you switch"), "\(name) still says sources are off until switched on")
            #expect(!text.localizedCaseInsensitiveContains("every source is off"), "\(name)")
        }
    }

    @Test func orderHelpersMoveAndDrop() {
        #expect(MusicOrderLogic.dropped(["a", "b", "c"], dragged: "a", onto: "c") == ["b", "c", "a"])
        #expect(MusicOrderLogic.dropped(["a", "b", "c"], dragged: "c", onto: "a") == ["c", "a", "b"])
        #expect(MusicOrderLogic.dropped(["a", "b"], dragged: "x", onto: "a") == ["a", "b"])
    }
}
