import Foundation

/// One saved (or saving) movie or episode.
struct DownloadRecord: Identifiable, Equatable, Sendable {
    enum State: String, Sendable { case queued, downloading, paused, done, failed }
    let itemID: String
    let kind: ContentKind
    let sourceID: UUID
    var seriesID: String?
    var title: String
    var subtitle: String?
    var artworkURL: String?
    var fileName: String?
    var state: State
    var bytesDone: Int64
    var bytesTotal: Int64
    var addedAt: Date
    var error: String?
    var id: String { itemID }
    var fraction: Double { bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : 0 }
}

/// The rules about files and addresses, kept apart from the service so they can be tested.
enum DownloadNaming {
    /// A file name that is safe on disk: the title's identity with anything but letters and digits made into "_", and the type of the stream's file.
    static func fileName(itemID: String, url: URL) -> String {
        let safe = String(itemID.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        let ext = url.pathExtension.lowercased()
        return safe + "." + (StreamCapabilities.isMediaFile(extension: ext) ? ext : "mp4")
    }

    /// A playlist such as .m3u8 is a list of pieces, not one file: it cannot be saved as a single download.
    static func isStreamingList(_ url: URL) -> Bool { StreamCapabilities.hlsExtensions.contains(url.pathExtension.lowercased()) || url.scheme == PortalLink.scheme }

    static func megabytes(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

/// Lets the stream resolver find a saved copy without knowing about the download service (which itself needs the resolver).
final class LocalFiles: @unchecked Sendable {
    private let lock = NSLock()
    private var finder: (@Sendable (String) -> URL?)?
    func set(_ f: @escaping @Sendable (String) -> URL?) { lock.withLock { finder = f } }
    func url(for itemID: String) -> URL? { lock.withLock { finder }?(itemID) }
}
