import Foundation
import Observation
import ImageIO
import UniformTypeIdentifiers

// A picture the person chose for a song, album, artist or playlist. It wins over everything the resolver finds, lives only on this device, and
// "reset" goes back to the automatic one. Keyed by the same key the resolver uses, so every cover of the same thing changes together.

@MainActor @Observable
final class MusicArtworkOverrides {
    static let shared = MusicArtworkOverrides()
    nonisolated static let maxPixels = 800
    private static let key = "music.artwork.overrides"

    private(set) var revision = 0
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let directory: URL

    init(defaults: UserDefaults = .standard, directory: URL = MusicStorage.subfolder("ArtworkOverrides")) {
        self.defaults = defaults; self.directory = directory
    }

    private var map: [String: String] { defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:] }

    /// The address the person chose for this thing, or nil.
    func address(for subject: MusicArtworkSubject) -> String? {
        _ = revision
        return map[subject.key]
    }

    func has(_ subject: MusicArtworkSubject) -> Bool { address(for: subject) != nil }

    /// Uses a picture from the web (for example one a metadata lookup found) without copying it.
    func set(address: String, for subject: MusicArtworkSubject) {
        var m = map
        m[subject.key] = address
        defaults.set(m, forKey: Self.key)
        revision += 1
    }

    /// Copies the chosen image into the app's own folder, scaled to at most `maxPixels` on the long side, and uses it. Returns false for a file that is not a picture.
    @discardableResult
    func setImage(from source: URL, for subject: MusicArtworkSubject) -> Bool {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil) else { return false }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: Self.maxPixels]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return false }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = LocalLibraryIndex.fnv12(subject.key) + "-" + String(Int(Date().timeIntervalSince1970 * 1000)) + ".jpg"
        let url = directory.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return false }
        removeFile(for: subject)
        set(address: url.absoluteString, for: subject)
        return true
    }

    func reset(_ subject: MusicArtworkSubject) {
        removeFile(for: subject)
        var m = map
        m[subject.key] = nil
        if m.isEmpty { defaults.removeObject(forKey: Self.key) } else { defaults.set(m, forKey: Self.key) }
        revision += 1
    }

    private func removeFile(for subject: MusicArtworkSubject) {
        guard let a = map[subject.key], let u = URL(string: a), u.isFileURL, u.path.hasPrefix(directory.path) else { return }
        try? FileManager.default.removeItem(at: u)
    }
}
