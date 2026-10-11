import Foundation

/// Preferences are stored under "settings.<key>" and the schema is versioned, so a release that changes a key can convert
/// what earlier releases saved instead of silently resetting it. Run once at launch, before `AppSettings` reads anything.
enum SettingsMigrator {
    static let currentVersion = 2
    static let versionKey = "settings.version"

    @discardableResult
    static func migrate(_ d: UserDefaults) -> Int {
        let from = d.object(forKey: versionKey) as? Int ?? 1
        guard from < currentVersion else { return from }
        if from < 2 {
            // v1 → v2: hardware decoding and deinterlacing became three-way choices; the amber/violet accents were renamed.
            if let hw = d.object(forKey: "settings.hwdec") as? Bool { d.set((hw ? HardwareDecoding.automatic : .software).rawValue, forKey: "settings.hwdec2") }
            if let di = d.object(forKey: "settings.deinterlace") as? Bool { d.set((di ? DeinterlaceMode.on : .automatic).rawValue, forKey: "settings.deinterlace2") }
            switch d.string(forKey: "settings.accent") {
            case "Violet": d.set(AccentChoice.purple.rawValue, forKey: "settings.accent")
            case "Amber": d.set(AccentChoice.coral.rawValue, forKey: "settings.accent")
            default: break
            }
            // The old two-value density keeps its meaning; "Comfortable" and "Compact" are still valid names.
        }
        d.set(currentVersion, forKey: versionKey)
        return currentVersion
    }
}
