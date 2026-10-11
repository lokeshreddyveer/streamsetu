import Foundation

/// When the Mac app was renamed its bundle identifier changed, and macOS keeps preferences per identifier. This copies what the
/// old identifier saved into the new one, once, without overwriting anything already set under the new one.
enum LegacyDefaults {
    @discardableResult
    static func migrate(from oldDomain: String, into target: UserDefaults, flag: String = "legacyDefaultsMigrated") -> Int {
        guard !target.bool(forKey: flag) else { return 0 }
        defer { target.set(true, forKey: flag) }
        guard let old = UserDefaults.standard.persistentDomain(forName: oldDomain) ?? UserDefaults(suiteName: oldDomain)?.persistentDomain(forName: oldDomain) else { return 0 }
        var copied = 0
        for (k, v) in old where target.object(forKey: k) == nil && !k.hasPrefix("NS") && !k.hasPrefix("Apple") { target.set(v, forKey: k); copied += 1 }
        return copied
    }
}
