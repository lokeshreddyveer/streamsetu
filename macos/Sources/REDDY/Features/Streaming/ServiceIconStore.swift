import AppKit

/// The official icons of the services, bundled with the app and decoded once at launch so the Services list opens with them already in place
/// (no network, works offline). A service without a bundled icon returns nil and the list shows its letter tile.
@MainActor
enum ServiceIconStore {
    private static var cache: [String: NSImage] = [:]
    private static var started = false

    /// Decodes every bundled icon off the main thread, once. Safe to call again.
    static func preload() {
        guard !started else { return }
        started = true
        let ids = ProviderID.allCases.map(\.rawValue)
        Task.detached(priority: .utility) {
            var loaded: [String: NSImage] = [:]
            for id in ids { if let image = decode(id) { loaded[id] = image } }
            await MainActor.run { for (id, image) in loaded { cache[id] = image } }
        }
    }

    /// Synchronous, from memory. Falls back to a direct read when the preload has not finished.
    static func icon(for id: ProviderID) -> NSImage? {
        if let image = cache[id.rawValue] { return image }
        guard let image = decode(id.rawValue) else { return nil }
        cache[id.rawValue] = image
        return image
    }

    /// Test hook: waits until the preload has filled the cache.
    static func preloadAndWait() async {
        for id in ProviderID.allCases { if cache[id.rawValue] == nil, let image = decode(id.rawValue) { cache[id.rawValue] = image } }
    }

    nonisolated static func url(_ id: String) -> URL? {
        if let url = Bundle.main.url(forResource: id, withExtension: "png", subdirectory: "ServiceIcons") { return url }
        #if DEBUG
        // swift run and swift test have no app bundle, so the file is read from the package's Resources folder.
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let file = packageRoot.appendingPathComponent("Resources/ServiceIcons/\(id).png")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
        #else
        return nil
        #endif
    }

    nonisolated private static func decode(_ id: String) -> NSImage? { url(id).flatMap { NSImage(contentsOf: $0) } }
}
