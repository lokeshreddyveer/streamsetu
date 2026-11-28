import Foundation

/// The app's own AcoustID application key, built in as scrambled bytes (see Scripts/gen-builtin-key.py) and joined in memory only while a request is made.
/// It is the developer's key, never shown, logged or stored in the source. A key saved in the Keychain wins over it; a build without the generated file has none.
enum BuiltInAcoustID {
    private static let underTest = Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
        || ProcessInfo.processInfo.arguments.contains { $0.contains(".xctest") }

    static func applicationKey() -> String? {
        if underTest { return nil }
        #if STREAMSETU_BUILTIN_ACOUSTID
        return BuiltInTMDB.assemble(chunks: GeneratedAcoustID.chunks, order: GeneratedAcoustID.order, mask: GeneratedAcoustID.mask)
        #else
        return nil
        #endif
    }
}
