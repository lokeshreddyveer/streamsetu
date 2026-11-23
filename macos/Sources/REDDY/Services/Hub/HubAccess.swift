import Foundation
import Security

// Keys for the extra services. Order for every service: the person's own key first, then the key built into this build (scrambled; see Scripts/gen-builtin-key.py), else the service is off.
// A key is sent only in a header or a JSON body, never in a URL, and never logged.

enum BuiltInFanart {
    static func token() -> String? {
        #if STREAMSETU_BUILTIN_FANART
        return BuiltInTMDB.assemble(chunks: GeneratedFanart.chunks, order: GeneratedFanart.order, mask: GeneratedFanart.mask)
        #else
        return nil
        #endif
    }
}
enum BuiltInTVDB {
    static func token() -> String? {
        #if STREAMSETU_BUILTIN_TVDB
        return BuiltInTMDB.assemble(chunks: GeneratedTVDB.chunks, order: GeneratedTVDB.order, mask: GeneratedTVDB.mask)
        #else
        return nil
        #endif
    }
}

/// Compile-time defaults. TheTVDB's built-in key is ON by default (the owner decided to enable it; TheTVDB's written approval for shipping a project key is still pending, so the credit link, the 7-day expiry and the shared pause on a refused key all stay).
enum HubDefaults {
    static let fanartBuiltInDefaultOn = true
    static let tvdbBuiltInDefaultOn = true
    static let tvmazeDefaultOn = true
    /// Whether a screen that shows a TheTVDB-sourced field carries a quiet credit footer. Off: no provider name appears on a content screen; the credit lives in Settings, under Credits. Same on Android.
    static let tvdbAttributionOnScreens = false
}

enum HubAttribution {
    static let tvdbFooter = "Data from TheTVDB.com"
    static let tvdbLink = "https://thetvdb.com"
    static let fanartCredit = "Artwork from fanart.tv"
    static let fanartLink = "https://fanart.tv"
    static let tvmazeCredit = "Episode and schedule data from TVmaze (tvmaze.com), licensed CC BY-SA"
    static let tvmazeLink = "https://www.tvmaze.com"

    /// The footer line for a screen, given the sources of the fields it shows: only TheTVDB-sourced data ever produces one.
    static func footer(provenance: Set<HubSource>, onScreens: Bool = HubDefaults.tvdbAttributionOnScreens) -> String? {
        onScreens && provenance.contains(.tvdb) ? tvdbFooter : nil
    }
}

/// Where the person's own keys are kept. The Keychain on device; memory in tests.
protocol HubSecretStore: Sendable {
    func get(_ account: String) -> String?
    func set(_ value: String?, for account: String)
}

#if DEBUG
final class MemorySecretStore: HubSecretStore, @unchecked Sendable {
    private let lock = NSLock(); private var items: [String: String] = [:]
    func get(_ account: String) -> String? { lock.withLock { items[account] } }
    func set(_ value: String?, for account: String) { lock.withLock { items[account] = value } }
}
#endif

final class KeychainSecretStore: HubSecretStore, @unchecked Sendable {
    private let service: String
    init(service: String = "app.streamsetu.hub") { self.service = service }
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    func get(_ account: String) -> String? {
        var q = query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    func set(_ value: String?, for account: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard let value, !value.isEmpty, let d = value.data(using: .utf8) else { return }
        var q = query(account); q[kSecValueData as String] = d
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}

/// Which credential a service uses, with its toggle and its 7-day pause after the built-in key is refused (401/403).
struct HubAccess: @unchecked Sendable {
    enum Origin: String, Sendable, Equatable { case own, builtIn, none }

    static let tvdbTokenLife: TimeInterval = 30 * 86400

    let source: HubSource
    var secrets: any HubSecretStore
    var builtIn: @Sendable () -> String?
    var defaults: UserDefaults = .standard
    var now: @Sendable () -> Date = { Date() }

    static func accessKey(_ s: HubSource) -> String { "hub.\(s.rawValue).own" }
    /// TheTVDB subscriber PIN (with the person's own subscriber key).
    static let tvdbPinAccount = "hub.tvdb.pin"
    var rejectedKey: String { "hub.\(source.rawValue).builtIn.rejectedAt" }
    var enabledKey: String { "hub.\(source.rawValue).enabled" }

    var enabled: Bool {
        get {
            if defaults.object(forKey: enabledKey) != nil { return defaults.bool(forKey: enabledKey) }
            switch source { case .fanart: return HubDefaults.fanartBuiltInDefaultOn; case .tvdb: return HubDefaults.tvdbBuiltInDefaultOn
            case .tvmaze: return HubDefaults.tvmazeDefaultOn; default: return true }
        }
        nonmutating set { defaults.set(newValue, forKey: enabledKey) }
    }
    var ownKey: String? { secrets.get(Self.accessKey(source)).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } }
    var pin: String? { secrets.get(Self.tvdbPinAccount).flatMap { $0.isEmpty ? nil : $0 } }
    func setOwnKey(_ k: String?) { secrets.set(k?.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.accessKey(source)); clearRejection() }

    private var pausePolicy: BuiltInKeyPause { BuiltInKeyPause(storageKey: rejectedKey, defaults: defaults, now: now) }
    var builtInRejected: Bool { pausePolicy.isPaused }
    func markBuiltInRejected() { pausePolicy.reportRefused(ownKeyInUse: ownKey != nil) }
    func clearRejection() { pausePolicy.clear() }
    var builtInUsable: Bool { !builtInRejected && builtIn() != nil }

    /// TVmaze needs no key. Other services: own key, else the built-in one (unless paused), else off.
    var origin: Origin {
        guard enabled else { return .none }
        if source == .tvmaze { return .builtIn }
        if ownKey != nil { return .own }
        return builtInUsable ? .builtIn : .none
    }
}

extension HubAccess {
    /// The access of a service as the app uses it: keys in the Keychain, the built-in key of this build (if any).
    static func standard(_ s: HubSource, secrets: any HubSecretStore = KeychainSecretStore(), defaults: UserDefaults = .standard) -> HubAccess {
        HubAccess(source: s, secrets: secrets, builtIn: { switch s { case .fanart: BuiltInFanart.token(); case .tvdb: BuiltInTVDB.token(); default: nil } }, defaults: defaults)
    }

    /// The plain status line shown in Settings (the only place a service is named).
    var statusLine: String {
        if !enabled { return "Off" }
        if source == .tvmaze { return "Working" }
        if ownKey != nil { return "Using your key" }
        if builtInRejected { return "Paused for \(Int(Retention.builtInKeyPause / Retention.day)) days: the built-in key was refused" }
        if builtIn() != nil { return "Using the built-in key" }
        return source == .tvdb ? "No built-in key in this build: add your own key" : "No key available"
    }
}

/// What a fanart.tv request carries: the project key always, and the person's personal key in addition (it also skips the 7-day delay on new images).
struct FanartKeys: Sendable, Equatable {
    var projectKey: String
    var clientKey: String?

    static func resolve(_ a: HubAccess) -> FanartKeys? {
        guard a.enabled else { return nil }
        let own = a.ownKey
        if a.builtInUsable, let b = a.builtIn() { return FanartKeys(projectKey: b, clientKey: own) }
        if let own { return FanartKeys(projectKey: own, clientKey: nil) }       // no project key in this build: the person's key stands in
        return nil
    }
}
