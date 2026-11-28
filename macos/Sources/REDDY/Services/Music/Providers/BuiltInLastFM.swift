import Foundation

/// The optional Last.fm application key and shared secret built into the app (see Scripts/gen-builtin-key.py). They exist in the program only as
/// scrambled bytes, joined in memory for the moment a request is signed. A person's own keys, when entered in Settings, always win over these.
/// A build without the generated files simply has no built-in keys, and Last.fm then needs the person's own.
enum BuiltInLastFM {
    /// Tests never use the built-in keys, whatever the build contains.
    private static let underTest = Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
        || ProcessInfo.processInfo.arguments.contains { $0.contains(".xctest") }

    static var isAvailable: Bool { apiKey() != nil && sharedSecret() != nil }

    static func apiKey() -> String? {
        if underTest { return nil }
        #if STREAMSETU_BUILTIN_LASTFM
        return BuiltInTMDB.assemble(chunks: GeneratedLastFM.chunks, order: GeneratedLastFM.order, mask: GeneratedLastFM.mask)
        #else
        return nil
        #endif
    }

    static func sharedSecret() -> String? {
        if underTest { return nil }
        #if STREAMSETU_BUILTIN_LASTFM_SECRET
        return BuiltInTMDB.assemble(chunks: GeneratedLastFMSecret.chunks, order: GeneratedLastFMSecret.order, mask: GeneratedLastFMSecret.mask)
        #else
        return nil
        #endif
    }
}
