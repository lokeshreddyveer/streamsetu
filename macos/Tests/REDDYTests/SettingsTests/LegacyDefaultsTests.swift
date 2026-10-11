import Testing
import Foundation
@testable import REDDY

@Suite("Settings kept across the rename") struct LegacyDefaultsTests {
    @Test func theOldIdentifiersSettingsAreCopiedOnceAndNothingIsOverwritten() {
        let oldName = "old-\(UUID().uuidString)"
        let old = UserDefaults(suiteName: oldName)!
        old.set("Dracula", forKey: "settings.theme"); old.set(true, forKey: "settings.autoresume"); old.set("x", forKey: "NSWindow Frame")
        old.synchronize()
        let target = UserDefaults(suiteName: "new-\(UUID().uuidString)")!
        target.set("Nord", forKey: "settings.theme")                        // already chosen under the new name: kept
        let n = LegacyDefaults.migrate(from: oldName, into: target)
        #expect(n == 1 && target.string(forKey: "settings.theme") == "Nord" && target.bool(forKey: "settings.autoresume"))
        #expect(target.object(forKey: "NSWindow Frame") == nil, "system keys are not copied")
        old.set("later", forKey: "settings.later")
        #expect(LegacyDefaults.migrate(from: oldName, into: target) == 0 && target.object(forKey: "settings.later") == nil, "only once")
        old.removePersistentDomain(forName: oldName)
    }
}
