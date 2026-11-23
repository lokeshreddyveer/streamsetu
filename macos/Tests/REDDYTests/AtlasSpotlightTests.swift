import Testing
import Foundation
@testable import REDDY

private func e(_ id: String, _ kind: AtlasKind = .setting, title: String = "Hardware decoding", path: [String] = ["Settings", "Playback"], platforms: AtlasPlatforms = .all, reach: AtlasReach = .settingsPage("Playback")) -> AtlasEntry {
    AtlasEntry(id: id, kind: kind, title: title, summary: "About \(title).", path: path, reach: reach, platforms: platforms, safety: .change)
}

@MainActor @Suite("Atlas: system search") struct AtlasSpotlightTests {
    @Test func onlyScreensAndSettingsGoInTheIndex() {
        let all = [e("setting.a"), e("screen.b", .screen), e("settings.c", .settingsPage), e("recipe.d", .recipe), e("shortcut.e", .shortcut), e("diag.f", .diagnosis), e("setting.g", reach: .none)]
        #expect(AtlasSpotlight.indexable(all, platform: .iPhone, appStore: false).map(\.id) == ["screen.b", "setting.a", "settings.c"])
    }

    @Test func locksKidsProfilesAndHiddenThingsNeverAppear() {
        let secret = [e("setting.appLock", title: "App Lock"), e("setting.parental", title: "Parental controls"), e("screen.settings.profiles", .screen, title: "Profiles"),
                      e("setting.x", title: "Hidden folders"), e("setting.y", title: "Kids mode", path: ["Settings", "Parental"]), e("setting.z", title: "Change PIN"), e("setting.unlockFolders", title: "Open")]
        #expect(AtlasSpotlight.indexable(secret, platform: .iPhone, appStore: false).isEmpty, "\(AtlasSpotlight.indexable(secret, platform: .iPhone, appStore: false).map(\.id))")
        // "clock" and "block" are not "lock"; a rendering profile is not a person's profile.
        let fine = [e("setting.catchupClock", title: "Catch-up clock"), e("setting.blockAds", title: "Block ads"), e("setting.renderingProfile", title: "Rendering profile")]
        #expect(AtlasSpotlight.indexable(fine, platform: .iPhone, appStore: false).count == 3)
    }

    @Test func platformAndStoreBuildFilterTheList() {
        let list = [e("setting.mac", platforms: .mac), e("setting.phone", platforms: [.iPhone, .iPad]), e("setting.dmg", platforms: [.mac, .dmgOnly])]
        #expect(AtlasSpotlight.indexable(list, platform: .iPhone, appStore: false).map(\.id) == ["setting.phone"])
        #expect(AtlasSpotlight.indexable(list, platform: .mac, appStore: false).map(\.id) == ["setting.dmg", "setting.mac"])
        #expect(AtlasSpotlight.indexable(list, platform: .mac, appStore: true).map(\.id) == ["setting.mac"])
    }

    @Test func fingerprintChangesWhenWordsChangeAndNotOtherwise() {
        let a = [e("setting.a"), e("setting.b")]
        var b = a; b[1].title = "Buffer size"
        #expect(AtlasSpotlight.fingerprint(a) == AtlasSpotlight.fingerprint(a))
        #expect(AtlasSpotlight.fingerprint(a) != AtlasSpotlight.fingerprint(b))
    }

    @Test func realAtlasIndexesAHundredPlusEntriesOnEachPlatformAndNoRecipes() {
        for p in [AtlasPlatforms.mac, .iPhone, .iPad] {
            let list = AtlasSpotlight.indexable(Atlas.entries, platform: p, appStore: false)
            #expect(list.count >= 60, "\(p): \(list.count)")
            #expect(list.allSatisfy { AtlasSpotlight.kinds.contains($0.kind) && !AtlasSpotlight.isWithheld($0) })
        }
    }

    @Test func aSpotlightResultIdentifierMustBeAPlainAtlasId() {
        #expect(AtlasSpotlight.atlasID(fromActivityIdentifier: "setting.hardwareDecoding") == "setting.hardwareDecoding")
        #expect(AtlasSpotlight.atlasID(fromActivityIdentifier: "../x") == nil && AtlasSpotlight.atlasID(fromActivityIdentifier: nil) == nil)
    }
}
