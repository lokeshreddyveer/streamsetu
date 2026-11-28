import Testing
import Foundation
@testable import REDDY

@Suite("Music follow-up wiring") @MainActor struct FollowUpWiringTests {
    private func temp() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("musicfollowup-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    // MARK: backup exclusion

    @Test func downloadsAndCacheFoldersAreExcludedFromBackup() throws {
        let root = temp(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = MusicStorage.ensureUnbacked(root.appendingPathComponent("Downloads", isDirectory: true))
        #expect(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        let cache = MusicStorage.ensureUnbacked(root.appendingPathComponent("AudioCache", isDirectory: true))
        #expect(try cache.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    // MARK: network policy

    @Test func transfersRefuseLocalAndPrivateAddresses() {
        #expect(MusicTransfer.isAllowed(URL(string: "https://example.com/a.mp3")!))
        #expect(!MusicTransfer.isAllowed(URL(string: "http://127.0.0.1/a.mp3")!))
        #expect(!MusicTransfer.isAllowed(URL(string: "https://192.168.1.4/a")!))
        #expect(!MusicTransfer.isAllowed(URL(string: "ftp://example.com/a")!))
        #expect(throws: Error.self) { try MusicTransfer.prepared(URLRequest(url: URL(string: "http://localhost/x")!)) }
    }

    // MARK: defaults keys

    @Test func musicKeyGroupsDoNotOverlapAndPortableOnesAreKnown() {
        let groups = [MusicDefaultsKeys.portable, MusicDefaultsKeys.deviceSettings, MusicDefaultsKeys.sourceChoices, MusicDefaultsKeys.activity]
        #expect(groups.reduce(0) { $0 + $1.count } == MusicDefaultsKeys.all.count)
        #expect(MusicDefaultsKeys.all.allSatisfy { $0.hasPrefix("music.") })
        #expect(MusicDefaultsKeys.portable.isSubset(of: AppSettings.knownKeys))
        #expect(MusicDefaultsKeys.all.contains(MusicThemeSettings.paletteKey) && MusicDefaultsKeys.all.contains(MusicLyricsPrefs.blurKey))
        #expect(MusicDefaultsKeys.all.contains(MusicPluginUpdates.weeklyKey) && MusicDefaultsKeys.all.contains(MusicAdaptiveSettings.defaultsKey))
    }

    @Test func resetAndWipeTouchTheRightGroups() throws {
        let d = try #require(UserDefaults(suiteName: "musicfollowup-\(UUID().uuidString)"))
        for k in MusicDefaultsKeys.all { d.set("x", forKey: k) }
        MusicDefaultsKeys.wipeActivity(d)
        #expect(MusicDefaultsKeys.activity.allSatisfy { d.object(forKey: $0) == nil })
        #expect(MusicDefaultsKeys.portable.allSatisfy { d.object(forKey: $0) != nil })
        MusicDefaultsKeys.resetPreferences(d)
        #expect(MusicDefaultsKeys.portable.union(MusicDefaultsKeys.deviceSettings).allSatisfy { d.object(forKey: $0) == nil })
        #expect(MusicDefaultsKeys.sourceChoices.allSatisfy { d.object(forKey: $0) != nil })
    }

    @Test func backupValuesAreValidated() {
        #expect(MusicDefaultsKeys.typedValue("music.lyrics.textStep", "3") as? Int == 3)
        #expect(MusicDefaultsKeys.typedValue("music.lyrics.textStep", "9") == nil)
        #expect(MusicDefaultsKeys.typedValue("music.theme.palette", "nonsense") == nil)
        #expect(MusicDefaultsKeys.typedValue("music.enabled", "x") == nil)
    }

    // MARK: lock gate for plugins

    @Test func pluginUpdatesAndInstallsAreHeldWhileGated() async throws {
        let dir = temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = try #require(UserDefaults(suiteName: "musicfollowup-\(UUID().uuidString)"))
        let manager = MusicPluginManager(registry: MusicRegistry(defaults: defaults), directory: dir)
        manager.updateSource = { _ in URL(string: "https://example.com/p.sbplugin") }
        manager.isAllowed = false
        #expect(await manager.checkForUpdates().isEmpty)
        await #expect(throws: Error.self) {
            _ = try await manager.install(fromRemote: URL(string: "https://example.com/p.sbplugin")!, confirm: { _ in true })
        }
        let updates = MusicPluginUpdates(plugins: manager, defaults: defaults)
        await updates.check()
        #expect(updates.lastCheck == nil)
    }

    // MARK: atlas

    @Test func everyDeclaredMusicScreenIsTaggedInAView() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/REDDY")
        var text = ""
        for dir in ["Features", "Application"] {
            let en = FileManager.default.enumerator(at: root.appendingPathComponent(dir), includingPropertiesForKeys: nil)
            for case let u as URL in en ?? FileManager.default.enumerator(atPath: "/")! where u.pathExtension == "swift" { text += (try? String(contentsOf: u, encoding: .utf8)) ?? "" }
        }
        let screens = AtlasMusicScreens.all.filter { $0.id.hasPrefix("screen.music.") }.map(\.id)
        #expect(screens.contains("screen.music.sources") && screens.contains("screen.music.karaoke"))
        for id in screens { #expect(text.contains("atlasScreen(\"\(id)\")"), "not tagged: \(id)") }
    }

    // MARK: wording

    private func table(_ code: String) throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Localization/\(code).lproj/Localizable.strings")
        return try #require(NSDictionary(contentsOf: url) as? [String: String])
    }

    /// Every fixed string the Music screens show through `Localized.string` or a literal `Text` has an entry in Hindi and Telugu (English is the key itself).
    @Test func musicWordingExistsInEnglishHindiAndTelugu() throws {
        let hi = try table("hi"), te = try table("te")
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/REDDY/Features/Music")
        let skip: Set<String> = ["MusicPlayerViews.swift", "MusicEffectsView.swift", "MusicPlaybackSettingsSection.swift", "MusicPlayerSettingsSection.swift"]
        let re = try NSRegularExpression(pattern: #"(?:Localized\.string\(|\bText\()\s*"((?:[^"\\\n]|\\.)*)""#)
        var keys = Set<String>()
        let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        for case let u as URL in en ?? FileManager.default.enumerator(atPath: "/")! where u.pathExtension == "swift" && !skip.contains(u.lastPathComponent) {
            let s = (try? String(contentsOf: u, encoding: .utf8)) ?? ""
            for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                guard let r = Range(m.range(at: 1), in: s) else { continue }
                let k = String(s[r]).replacingOccurrences(of: "\\\"", with: "\"")
                if k.contains("\\(") || k.range(of: "[A-Za-z]{2}", options: .regularExpression) == nil { continue }
                if !k.contains(" ") && k.contains(".") && k.lowercased() == k { continue }
                keys.insert(k)
            }
        }
        #expect(keys.count > 150, "found \(keys.count)")
        for k in keys.sorted() { #expect(hi[k] != nil, "hi missing: \(k)"); #expect(te[k] != nil, "te missing: \(k)") }
        #expect(Localized.string("Never Play List") == "Never Play List")
    }
}
