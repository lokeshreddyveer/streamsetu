import Foundation
import Security

struct KeychainError: Error, LocalizedError, Sendable {
    let status: OSStatus
    var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}

/// A credential store backed by the system Keychain.
protocol KeychainStore: CredentialStore {
    func load(ref: String, migrating: Bool) throws -> Credentials?
    /// Moves the given logins between this device's own Keychain and iCloud Keychain, and uses that mode from now on.
    func setSynchronizable(_ on: Bool, migrating refs: [String])
}

extension KeychainStore {
    func setSynchronizable(_ on: Bool, migrating refs: [String]) {}
}

/// Stores IPTV logins in the macOS Keychain. Nothing secret is written to the database or to preferences.
final class KeychainManager: KeychainStore, @unchecked Sendable {
    private let service: String
    /// macOS only. `true` lets any application of this user read an item without a prompt, which is what a build without a
    /// stable code identity needs. A build signed by an Apple team passes `false`: the item then belongs to that team's apps
    /// alone, which is both safer and stable across updates.
    private let openAccess: Bool
    private let modeLock = NSLock()
    private var _synchronizable = false
    /// Logins are kept in iCloud Keychain, so they follow the person to their other devices. Off by default.
    var synchronizable: Bool { get { modeLock.withLock { _synchronizable } } set { modeLock.withLock { _synchronizable = newValue } } }
    init(service: String = "app.reddy.iptv.credentials", openAccess: Bool = true) { self.service = service; self.openAccess = openAccess }

    #if os(macOS)
    /// Access rule for the item: any application of this user may read it without a prompt. REDDY is distributed without a
    /// paid developer identity, so a rule naming "this app" breaks whenever the signing identity of a build differs from the
    /// one that saved the login, and the user is asked for their Keychain password again. The item still lives in the login
    /// keychain, which is locked with the user's account, and is never written anywhere else.
    private func appAccess() -> SecAccess? {
        var access: SecAccess?
        // NULL trusts only the creating app; the rule that lets any app read without a prompt is an access-control entry with
        // no application list, so create the default access and clear the list on its decrypt entry. (An empty array passed
        // to SecAccessCreate does not mean "any app": it trusts none, and every read prompts.)
        guard SecAccessCreate("REDDY login" as CFString, nil, &access) == errSecSuccess, let access else { return nil }
        var list: CFArray?
        guard SecAccessCopyACLList(access, &list) == errSecSuccess, let acls = list as? [SecACL] else { return access }
        for acl in acls {
            let auths = SecACLCopyAuthorizations(acl) as? [String] ?? []
            guard auths.contains("ACLAuthorizationDecrypt") || auths.contains("ACLAuthorizationAny") else { continue }
            var apps: CFArray?, desc: CFString?, selector = SecKeychainPromptSelector()
            guard SecACLCopyContents(acl, &apps, &desc, &selector) == errSecSuccess else { continue }
            SecACLSetContents(acl, nil, desc ?? ("REDDY login" as CFString), SecKeychainPromptSelector(rawValue: 0))
        }
        return access
    }

    private func attachAccess(_ q: inout [String: Any]) { if openAccess, !synchronizable, let access = appAccess() { q[kSecAttrAccess as String] = access } }
    private func canRebuildAccess() -> Bool { openAccess && appAccess() != nil }
    #else
    // iOS: items belong to this app alone and are protected by the device; no access list exists.
    private func attachAccess(_ q: inout [String: Any]) {
        // an item that syncs must be readable on the other devices too, so it cannot be tied to this one
        q[kSecAttrAccessible as String] = synchronizable ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    }
    private func canRebuildAccess() -> Bool { false }
    #endif

    /// `exact` picks one kind of item (synced or not); without it, the current mode decides, and in sync mode both are found.
    private func baseQuery(_ ref: String, exact: Bool? = nil) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: ref]
        if let exact {
            q[kSecAttrSynchronizable as String] = exact
            #if os(macOS)
            if exact { q[kSecUseDataProtectionKeychain as String] = true }       // iCloud Keychain items live in the data protection keychain
            #endif
        } else if synchronizable {
            q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            #if os(macOS)
            q[kSecUseDataProtectionKeychain as String] = true
            #endif
        }
        return q
    }

    func save(_ credentials: Credentials, ref: String) throws {
        let data = try JSONEncoder().encode(credentials)
        var q = baseQuery(ref)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            q[kSecValueData as String] = data
            attachAccess(&q)
            if synchronizable { q[kSecAttrSynchronizable as String] = true }
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func load(ref: String) throws -> Credentials? { try load(ref: ref, migrating: true) }

    func load(ref: String, migrating: Bool) throws -> Credentials? {
        var q = baseQuery(ref)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        var status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound, synchronizable {          // not moved to iCloud Keychain yet: it is still in this device's own
            var plain = baseQuery(ref, exact: false)
            plain[kSecReturnData as String] = true; plain[kSecMatchLimit as String] = kSecMatchLimitOne
            status = SecItemCopyMatching(plain as CFDictionary, &out)
        }
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainError(status: status) }
        let creds = try JSONDecoder().decode(Credentials.self, from: data)
        if migrating { migrateAccessIfNeeded(ref: ref, creds) }
        return creds
    }

    /// Logins saved by earlier builds carry a per-build partition list (a prompt after every rebuild). Re-create them once
    /// with the open access rule above. Best effort: if it fails the login keeps working as before.
    private func migrateAccessIfNeeded(ref: String, _ creds: Credentials) {
        let flag = "keychainAccess.v4.\(service).\(ref)"
        guard !UserDefaults.standard.bool(forKey: flag), canRebuildAccess() else { return }
        guard (try? delete(ref: ref)) != nil else { return }
        if (try? save(creds, ref: ref)) != nil { UserDefaults.standard.set(true, forKey: flag) }
        else { try? save(creds, ref: ref) }                    // never leave the login missing
    }

    func delete(ref: String) throws {
        let status = SecItemDelete(baseQuery(ref) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
        if synchronizable { SecItemDelete(baseQuery(ref, exact: false) as CFDictionary) }      // and a copy that was never moved
    }

    func setSynchronizable(_ on: Bool, migrating refs: [String]) {
        guard on != synchronizable else { return }
        let old = synchronizable
        var found: [(String, Credentials)] = []
        for r in refs { if let c = try? load(ref: r, migrating: false) { found.append((r, c)) } }
        synchronizable = on
        for (r, c) in found {
            if (try? save(c, ref: r)) != nil { SecItemDelete(baseQuery(r, exact: old) as CFDictionary) }     // remove the old kind only once the new one is saved
        }
    }
}
