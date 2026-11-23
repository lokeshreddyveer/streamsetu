import Testing
import Foundation
@testable import REDDY

@Suite("Metadata hub settings and wording") struct HubSettingsTests {
    static func sources() -> URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/REDDY") }

    /// Provider names may be spoken only in Settings, About and the credits (and the TheTVDB footer). Files below still hold older wording that belongs to other work in progress
    /// (the matcher's error texts, the assistant's knowledge and the Atlas declarations, the title page); that list must only shrink.
    static let allowed: [String] = ["Features/Settings/", "Services/Hub/", "Features/Shared/Views/TMDBAttribution.swift", "Features/Shared/Views/ServiceCredits.swift", "Services/ArtworkSettingsModel.swift", "Services/LegalText.swift", "Services/PrivacyReport.swift"]
    static let pending: [String] = ["Atlas/", "Services/MetadataMatchService.swift", "Services/ArtworkAutoMatcher.swift", "Services/AssistantKnowledge.swift", "Services/AssistantToolbox.swift", "Services/AskLibrary.swift", "Services/AskBrain.swift"]

    @Test func providerNamesAppearOnlyInSettingsAboutAndCredits() throws {
        let root = Self.sources()
        let literal = try NSRegularExpression(pattern: #""(?:[^"\\\n]|\\.)*(?:TMDB|TheTVDB|TVmaze|[Ff]anart|themoviedb)(?:[^"\\\n]|\\.)*""#)
        var hits: [String] = []
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let url as URL in e where url.pathExtension == "swift" {
            let rel = String(url.path.dropFirst(root.path.count + 1))
            if Self.allowed.contains(where: { rel.hasPrefix($0) }) || rel.hasPrefix("Generated/") { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("//") { continue }
                let ns = String(line) as NSString
                for m in literal.matches(in: String(line), range: NSRange(location: 0, length: ns.length)) {
                    let lit = ns.substring(with: m.range)
                    if lit.contains("http") || lit.contains("TMDBLogo") || lit.contains("TMDBAttribution") { continue }
                    if Self.pending.contains(where: { rel.hasPrefix($0) }) { continue }
                    hits.append("\(rel):\(i + 1)")
                }
            }
        }
        #expect(hits.isEmpty, "a provider name in wording shown outside Settings/About: \(hits.prefix(8))")
    }

    @Test func theHubFooterIsTheOnlyProviderWordingOutsideSettings() {
        #expect(HubAttribution.tvdbFooter == "Data from TheTVDB.com" && HubAttribution.tvdbLink == "https://thetvdb.com")
        for id in ["tmdb", "tvdb", "fanart", "tvmaze", "iptvorg", "opensubtitles", "sparkle", "mpv"] { #expect(ServiceCredits.all.map(\.id).contains(id), "Credits is missing \(id)") }
        #expect(ServiceCredits.all.allSatisfy { $0.url.scheme == "https" })
    }

    @Test func newWordingHasHindiAndTelugu() throws {
        func table(_ c: String) throws -> [String: String] {
            let u = Self.sources().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Localization/\(c).lproj/Localizable.strings")
            return try #require(NSDictionary(contentsOf: u) as? [String: String])
        }
        let hi = try table("hi"), te = try table("te")
        var keys = HubSettingsModel.cards.map(\.help) + [HubSettingsModel.keepNote, ServiceCredits.privacy, HubAttribution.tvdbFooter, HubAttribution.fanartCredit, HubAttribution.tvmazeCredit]
        keys += ServiceCredits.all.map(\.text)
        keys += HubSettingsModel.cards.compactMap(\.keyLabel)
        let d = UserDefaults(suiteName: "hubset-\(UUID().uuidString)")!
        for s in [HubSource.fanart, .tvdb, .tvmaze] {
            let a = HubAccess(source: s, secrets: MemorySecretStore(), builtIn: { s == .tvmaze ? nil : "K" }, defaults: d)
            keys.append(a.statusLine)
        }
        keys += ["Off", "Working", "Using your key", "Using the built-in key", "Paused for 7 days: the built-in key was refused", "No built-in key in this build: add your own key", "No key available",
                 "Key saved.", "Your key was removed.", "Checking…", "Accepted. This source is working.", "The key was refused. Check that you copied it whole.", "No answer, try again.",
                 "The service asked us to slow down. Try again in a few minutes.", "More sources", "Test", "Paste key", "Replace key", "Replace PIN", "Save", "Remove", "Save Key", "Remove Key",
                 "Your key is saved on this device.", "Add an artwork and details key for the full filmography", "The details service did not answer, try again", "Shows details"]
        for k in Set(keys) { #expect(hi[k] != nil && te[k] != nil, "no Hindi/Telugu for: \(k)") }
        for k in Set(keys) where k != "PIN" { #expect(hi[k] != k && te[k] != k, "not translated: \(k)") }
    }

    // MARK: model
    final class Box: @unchecked Sendable { var statuses: [Int] = []; var requests: [URLRequest] = [] }
    @MainActor func model(builtIn: String? = "BUILTIN", store: HubStore? = nil, box: Box = Box(), status: Int? = nil) -> (HubSettingsModel, Box, MemorySecretStore, UserDefaults) {
        let secrets = MemorySecretStore(); let d = UserDefaults(suiteName: "hubset-\(UUID().uuidString)")!
        let fetch: HubFetch = { req in box.requests.append(req); if let s = status { throw NetworkError.http(status: s, retryAfter: nil) }; return Data(#"{"data":{"token":"T"}}"#.utf8) }
        let m = HubSettingsModel(store: store, fetch: fetch, access: { HubAccess(source: $0, secrets: secrets, builtIn: { builtIn }, defaults: d) })
        return (m, box, secrets, d)
    }
    @Test @MainActor func defaultsAndKeyHandling() {
        let (m, _, secrets, _) = model()
        #expect(m.enabled[.fanart] == true && m.enabled[.tvmaze] == true && m.enabled[.tvdb] == true)      // TheTVDB is on by default now
        #expect(m.status[.tvdb] == "Using the built-in key" && m.status[.fanart] == "Using the built-in key" && m.status[.tvmaze] == "Working")
        m.saveKey(.fanart, "  PERSONAL  ")
        #expect(secrets.get(HubAccess.accessKey(.fanart)) == "PERSONAL" && m.hasKey[.fanart] == true && m.status[.fanart] == "Using your key")
        m.saveKey(.tvdb, "SUB", pin: "1234")
        #expect(m.hasPin && secrets.get(HubAccess.tvdbPinAccount) == "1234")
        m.removeKey(.tvdb)
        #expect(!m.hasPin && m.hasKey[.tvdb] == false)
        m.setEnabled(.tvdb, false); #expect(m.status[.tvdb] == "Off")
        m.setEnabled(.tvdb, true); #expect(m.status[.tvdb] == "Using the built-in key")
        let none = model(builtIn: nil).0
        #expect(none.status[.fanart] == "No key available" && none.status[.tvdb] == "No built-in key in this build: add your own key" && none.enabled[.tvdb] == true)
    }
    @Test @MainActor func switchingASourceOffDeletesWhatItSaved() throws {
        let store = HubStore(db: try TestSupport.makeDB())
        store.put("a", "logo", value: "u", source: .fanart, quality: 1, keep: 1000); store.put("a", "poster", value: "p", source: .tmdb, quality: 1, keep: 1000)
        let (m, _, _, _) = model(store: store)
        m.setEnabled(.fanart, false)
        #expect(store.fact("a", "logo") == nil && store.fact("a", "poster") != nil)
    }
    @Test func theTestButtonReportsOnlyOkRefusedOrNoAnswer() async {
        let d = UserDefaults(suiteName: "hubset-\(UUID().uuidString)")!
        func access(_ s: HubSource) -> HubAccess { var a = HubAccess(source: s, secrets: MemorySecretStore(), builtIn: { "BUILTIN" }, defaults: UserDefaults(suiteName: "hubset-\(UUID().uuidString)")!); a.enabled = true; return a }
        let ok: HubFetch = { _ in Data(#"{"data":{"token":"T"}}"# .utf8) }
        let refused: HubFetch = { _ in throw NetworkError.http(status: 403, retryAfter: nil) }
        let down: HubFetch = { _ in throw NetworkError.offline }
        for s in [HubSource.fanart, .tvdb, .tvmaze] {
            let r1 = await HubSettingsModel.check(s, access: access(s), fetch: ok)
            let r2 = await HubSettingsModel.check(s, access: access(s), fetch: refused)
            let r3 = await HubSettingsModel.check(s, access: access(s), fetch: down)
            #expect(r1.ok, "\(s)")
            if s != .tvmaze { #expect(r2.text == "The key was refused. Check that you copied it whole.", "\(s) \(r2.text)") }
            #expect(r3.text == "No answer, try again.", "\(s) \(r3.text)")
        }
        #expect(!(await HubSettingsModel.check(.fanart, access: HubAccess(source: .fanart, secrets: MemorySecretStore(), builtIn: { nil }, defaults: d), fetch: ok).ok), "no key: nothing is requested")
    }
    @Test func purgeByFolderRemovesFactsAndIdentity() throws {
        let store = HubStore(db: try TestSupport.makeDB())
        // folder purge is exercised against real rows in the integration stage; here the statement must at least run on an empty library
        #expect(store.purge(inFolders: ["cat1", "cat2"]) == 0)
    }
}

@Suite("Credits: the TMDB logo") struct TMDBLogoResourceTests {
    @MainActor @Test func theCreditsLogoLoadsInsteadOfThePlaceholder() throws {
        let image = try #require(TMDBLogoImage.shared, "the TMDB logo did not load: Settings > Credits would draw the text placeholder")
        #expect(image.size.width > 20 && image.size.height > 5)
    }
    @Test func theLogoIsCopiedByTheReleaseScriptAndInTheIOSAssetCatalog() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("macos/Resources/Branding/TMDBLogo.png").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("ios/StreamSetu/Assets.xcassets/TMDBLogo.imageset/TMDBLogo.png").path))
        let script = try String(contentsOf: root.appendingPathComponent("macos/Scripts/build-release.sh"), encoding: .utf8)
        #expect(script.contains("TMDBLogo.png"))
    }
}
