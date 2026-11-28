import Foundation

/// The one place the account layer is wired in. Build the YouTube Music provider with `YouTubeMusicAccountBuiltIns.session` as its session,
/// register it, then call `attach(provider:)`. Until then the provider is a guest and nothing here touches the network.
enum YouTubeMusicAccountBuiltIns {
    /// The session to give the provider. One for the whole app; it holds the active account's cookies.
    static let session = YouTubeMusicSessionImpl()

    /// The manager once attached. Views read it; it is nil before `attach`.
    @MainActor private(set) static var manager: YouTubeMusicAccountManager?

    /// Connects the account layer to a provider that was built with `session`. Returns nil (and does nothing) when the provider uses another
    /// session, because cookies could then never reach its requests. Safe to call again: the first call wins.
    @MainActor @discardableResult
    static func attach(provider: YouTubeMusicFullProvider, directory: URL = MusicHub.supportDirectory,
                       secrets: YTMSecretStore = YTMKeychainSecretStore()) -> YouTubeMusicAccountManager? {
        if let manager { return manager }
        guard let s = provider.client.session as? YouTubeMusicSessionImpl, s === session else { return nil }
        let store = YouTubeMusicAccountStore(directory: directory, secrets: secrets)
        let m = YouTubeMusicAccountManager(provider: provider, session: s, store: store)
        manager = m
        return m
    }

    /// Registers the optional history scrobbler (off until the person switches it on). Call after `attach`.
    @MainActor
    static func registerHistory(into registry: MusicRegistry) {
        guard let m = manager else { return }
        registry.register(m.historyProvider)
    }

    /// Test seam: forget the attached manager.
    @MainActor static func resetForTesting() { manager = nil }
}
