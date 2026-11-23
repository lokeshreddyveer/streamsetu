import Testing
import SwiftUI
import AppKit
@testable import REDDY

@MainActor @Suite("Guide hub: UI models and Settings snapshot") struct GuideUITests {
    func container() throws -> AppContainer {
        try AppContainer(databasePath: FileManager.default.temporaryDirectory.appendingPathComponent("guide-ui-\(UUID().uuidString).sqlite").path, credentials: InMemoryCredentialStore())
    }

    @Test func viewModelAddRejectsBadAddressesAndEnrichmentSwitchPersists() async throws {
        let c = try container()
        c.settings.defaultsStore.removeObject(forKey: GuideSettingsModel.enrichmentKey)      // a run that was stopped half way must not decide "on by default"
        let vm = GuideSourcesViewModel()
        vm.address = "not a web address"
        await vm.add(c)
        #expect(vm.message == GuideSourceManager.AddError.badAddress.localizedDescription && vm.model?.rows.isEmpty != false)
        vm.load(c)
        #expect(vm.model?.enrichmentEnabled == true, "on by default")
        c.settings.defaultsStore.set(false, forKey: GuideSettingsModel.enrichmentKey)      // no network in tests
        await vm.refresh(c)
        #expect(vm.message == "Nothing to refresh.")
        vm.setEnrichment(false, c)
        #expect(vm.model?.enrichmentEnabled == false)
        c.settings.defaultsStore.removeObject(forKey: GuideSettingsModel.enrichmentKey)
    }

    @Test func bannerAndDotModels() {
        #expect(GuideAvailability.nowNext.accessibilityLabel == "Guide available" && !GuideAvailability.none.showsDot)
        let m = GuideSettingsModel(rows: [.init(id: "a", title: "A", kind: .provider, host: nil, enabled: true, freshness: .init(level: .warning, key: "guide.updatedLongAgo", amount: 3), summary: "The guide was last updated 3 days ago.", findings: [])], enrichmentEnabled: true)
        #expect(m.worst == .warning)
    }

    static func model() -> GuideSettingsModel {
        func f(_ k: String, _ l: GuideFreshnessLevel, _ a: Int? = nil) -> GuideFreshness { .init(level: l, key: k, amount: a) }
        return GuideSettingsModel(rows: [
            .init(id: "provider:a", title: "Home playlist", kind: .provider, host: nil, enabled: true, freshness: f("guide.fresh", .fresh, 52), summary: "Guide is up to date.", findings: []),
            .init(id: "user:b", title: "Extra guide", kind: .userXMLTV, host: "example.test", enabled: true, freshness: f("guide.updatedLongAgo", .warning, 3), summary: "The guide was last updated 3 days ago.",
                  findings: [GuideFinding(key: "guide.updatedLongAgo", level: .warning, args: [3], text: "The guide was last updated 3 days ago.")]),
            .init(id: "provider:c", title: "Second playlist", kind: .provider, host: nil, enabled: true, freshness: f("guide.empty", .error), summary: "The guide holds no programmes.",
                  findings: [GuideFinding(key: "diag.emptyFile", level: .error, args: [], text: GuideMessages.text["diag.emptyFile"]!)]),
        ], enrichmentEnabled: true)
    }

    @Test func settingsPageSnapshotInTwoThemes() throws {
        let c = try container()
        let dir = ProcessInfo.processInfo.environment["GUIDE_SNAP_DIR"].map(URL.init(fileURLWithPath:))
        for (name, scheme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
            let view = GuideSourcesGroup(previewModel: Self.model()).environment(\.container, c).environment(\.colorScheme, scheme).frame(width: 760).padding(20)
                .background(scheme == .dark ? Color(white: 0.09) : Color(white: 0.97))
            let r = ImageRenderer(content: view); r.scale = 2
            let img = try #require(r.nsImage)
            let tiff = try #require(img.tiffRepresentation)
            let rep = try #require(NSBitmapImageRep(data: tiff))
            let png = try #require(rep.representation(using: .png, properties: [:]))
            #expect(png.count > 5000 && img.size.height > 200)
            if let dir { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); try png.write(to: dir.appendingPathComponent("settings-guide-\(name).png")) }
        }
    }
}
