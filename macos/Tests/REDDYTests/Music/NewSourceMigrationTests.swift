import Testing
import Foundation
@testable import REDDY

private struct PluginStub: MusicProvider {
    var info: MusicProviderInfo { MusicProviderInfo(id: "plugin-stub", name: "Stub", summary: "A plugin", kind: .plugin) }
    var capabilities: MusicCapabilities { [] }
}

@Suite("New built-in sources start on once") @MainActor struct NewSourceMigrationTests {
    private func defaults() -> UserDefaults {
        let suite = "music.newsource.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite) ?? .standard
        d.removePersistentDomain(forName: suite)
        return d
    }
    private func registry(_ d: UserDefaults) -> MusicRegistry {
        let r = MusicRegistry(defaults: d)
        MusicBuiltIns.register(into: r)
        return r
    }
    private let newID = JioSaavnDiscoveryProvider.id

    /// An install from before that source existed: everything of the default set is on except it, and no known set was ever written.
    private func existingInstall(_ d: UserDefaults) {
        let probe = registry(defaults())
        d.set(Array(MusicSetupPresets.defaultSet(registry: probe).subtracting([newID])).sorted(), forKey: "music.enabled")
    }

    @Test func freshInstallIsLeftToTheSetupScreen() {
        let d = defaults()
        let r = registry(d)
        #expect(r.adoptNewBuiltIns(setupDone: false).isEmpty)
        #expect(r.enabled.isEmpty && r.changeLog.isEmpty && d.object(forKey: MusicRegistry.knownBuiltInsKey) == nil)
    }

    @Test func existingInstallGetsTheNewSourceOnce() {
        let d = defaults(); existingInstall(d)
        let r = registry(d)
        #expect(!r.isEnabled(newID))
        #expect(r.adoptNewBuiltIns(setupDone: true) == [newID])
        #expect(r.isEnabled(newID))
        #expect(r.knownBuiltIns.isSuperset(of: r.all.filter { $0.info.kind == .builtIn }.map(\.id)))
        #expect(registry(d).isEnabled(newID))      // persisted
    }

    @Test func aSourceSwitchedOffAfterwardsStaysOff() {
        let d = defaults(); existingInstall(d)
        let r = registry(d)
        r.adoptNewBuiltIns(setupDone: true)
        r.setEnabled(false, id: newID)
        let next = registry(d)
        #expect(next.adoptNewBuiltIns(setupDone: true).isEmpty)
        #expect(!next.isEnabled(newID))
    }

    @Test func aSourceSwitchedOffBeforeTheKnownSetExistedStaysOff() {
        let d = defaults(); existingInstall(d)
        let first = registry(d)
        first.setEnabled(true, id: newID)
        first.setEnabled(false, id: newID)     // the person's own switch, kept in the change log
        let next = registry(d)
        #expect(next.adoptNewBuiltIns(setupDone: true).isEmpty)
        #expect(!next.isEnabled(newID))
    }

    @Test func signInSourcesAndLocalFilesStayOff() {
        let d = defaults(); existingInstall(d)
        let r = registry(d)
        r.adoptNewBuiltIns(setupDone: true)
        for id in ["local", "lastfm", "listenbrainz", "subsonic"] { #expect(!r.isEnabled(id), Comment(rawValue: id)) }
    }

    @Test func runningTwiceChangesNothingTheSecondTime() {
        let d = defaults(); existingInstall(d)
        let r = registry(d)
        #expect(!r.adoptNewBuiltIns(setupDone: true).isEmpty)
        let enabled = r.enabled, log = r.changeLog.count
        #expect(r.adoptNewBuiltIns(setupDone: true).isEmpty)
        #expect(r.enabled == enabled && r.changeLog.count == log)
    }

    @Test func theChangeLogSaysItWasNew() {
        let d = defaults(); existingInstall(d)
        let r = registry(d)
        r.adoptNewBuiltIns(setupDone: true)
        let entry = r.changeLog.last { $0.id == newID }
        #expect(entry?.on == true && entry?.reason == .newSource)
        #expect(MusicRegistryChangeLog.load(d).last?.reason == .newSource)
    }

    @Test func pluginsAreNeverTouched() {
        let d = defaults(); existingInstall(d)
        let r = registry(d)
        r.register(PluginStub())
        r.adoptNewBuiltIns(setupDone: true)
        #expect(!r.isEnabled("plugin-stub") && !r.knownBuiltIns.contains("plugin-stub"))
    }

    @Test func theKnownSetIsAChoiceThatResetAndWipeLeave() {
        #expect(MusicDefaultsKeys.sourceChoices.contains(MusicRegistry.knownBuiltInsKey))
        #expect(MusicDefaultsKeys.all.contains(MusicRegistry.knownBuiltInsKey))
    }

    @Test func recordingAfterSetupKeepsALaterOffChoice() {
        let d = defaults()
        let r = registry(d)
        for p in r.all { r.setEnabled(MusicSetupPresets.defaultSet(registry: r).contains(p.id) && p.id != newID, id: p.id, reason: .setup) }
        r.recordKnownBuiltIns()
        #expect(registry(d).adoptNewBuiltIns(setupDone: true).isEmpty)
    }
}
