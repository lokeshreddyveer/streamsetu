import CryptoKit
import Foundation
import Observation

/// One downloadable separation model.
struct MusicKaraokeModelEntry: Identifiable, Hashable, Sendable, Codable {
    var id: String
    /// Name shown to the person.
    var name: String
    var tier: MusicKaraokeTier
    /// Exact size in bytes of the file at `url`.
    var sizeBytes: Int64
    /// SHA-256 of that file, 64 lowercase hex characters.
    var sha256: String
    var licenseName: String
    /// The full licence or credit text shown before anything is downloaded.
    var licenseText: String
    /// HTTPS address of a Core ML model file (`.mlmodel`).
    var url: URL
    /// Replaces the tier's transform sizes and stem when the model needs different ones.
    var layoutOverride: MusicStemLayout?

    var layout: MusicStemLayout { layoutOverride ?? MusicStemLayout(stft: tier.config, stem: tier.stem) }
    /// Cache key part: changes with the model so an old model's songs are never played for a new one.
    var cacheStem: String { id }
}

/// THE PLACE TO ADD DOWNLOADABLE MODELS. It is empty on purpose: the app's own model ships inside the app (see `MusicKaraokeBundledModels`),
/// so nothing is fetched. To offer a download as well, append an entry:
///
///     MusicKaraokeModelEntry(id: "example-light", name: "Example (light)", tier: .light,
///                            sizeBytes: 12_345_678, sha256: "<64 hex characters>",
///                            licenseName: "Licence name", licenseText: "Full licence or credit text",
///                            url: URL(string: "https://host.example/model.mlmodel")!)
///
/// The size and hash are checked after download; a file that does not match both is deleted.
enum MusicKaraokeModelCatalog {
    static let entries: [MusicKaraokeModelEntry] = []
}

// MARK: Integrity

enum MusicKaraokeIntegrityError: Error, Equatable, Sendable { case sizeMismatch, hashMismatch, unreadable }

enum MusicKaraokeIntegrity {
    /// Streams the file through SHA-256 so a large model never sits in memory.
    static func sha256Hex(of url: URL) throws -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { throw MusicKaraokeIntegrityError.unreadable }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return MusicHash.hex(hasher.finalize())
    }

    static func sha256Hex(of data: Data) -> String { MusicHash.sha256(data) }

    static func verify(file: URL, size: Int64, sha256: String) throws {
        let actual = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
        guard let actual else { throw MusicKaraokeIntegrityError.unreadable }
        guard actual == size else { throw MusicKaraokeIntegrityError.sizeMismatch }
        guard try sha256Hex(of: file) == sha256.lowercased() else { throw MusicKaraokeIntegrityError.hashMismatch }
    }
}

// MARK: Downloading

protocol MusicKaraokeFileDownloading: Sendable {
    /// Writes the body of `url` to `destination`. `progress(received, expected)` is called as bytes arrive.
    func download(from url: URL, to destination: URL, progress: @Sendable (Int64, Int64) -> Void) async throws
}

/// Plain HTTPS download through the app's network path (proxy, secure DNS). Sends no cookies, no identifiers and no headers beyond the defaults.
struct MusicKaraokeURLSessionDownloader: MusicKaraokeFileDownloading {
    func download(from url: URL, to destination: URL, progress: @Sendable (Int64, Int64) -> Void) async throws {
        guard url.scheme?.lowercased() == "https" else { throw URLError(.appTransportSecurityRequiresSecureConnection) }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "GET"
        let (bytes, http) = try await MusicTransfer.bytes(for: request)
        guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        let expected = http.expectedContentLength
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let h = try FileHandle(forWritingTo: destination)
        defer { try? h.close() }
        var buf = Data(); var total: Int64 = 0; var lastReport: Int64 = 0
        for try await b in bytes {
            buf.append(b); total += 1
            if buf.count >= 262_144 { try h.write(contentsOf: buf); buf.removeAll(keepingCapacity: true) }
            if total - lastReport >= 262_144 { lastReport = total; progress(total, expected) }
        }
        if !buf.isEmpty { try h.write(contentsOf: buf) }
        progress(total, expected)
    }
}

// MARK: Manager

struct MusicKaraokeInstalledModel: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var tier: MusicKaraokeTier
    var compiledName: String
    var sizeBytes: Int64
    var layout: MusicStemLayout
    /// Nil for models saved before families existed, which are the spectrogram-in, spectrogram-out kind.
    var family: MusicStemFamily? = nil
    /// True for a model that ships inside the app: it cannot be deleted and needs no download.
    var isBundled: Bool? = nil
    var licenseName: String? = nil
}

enum MusicKaraokeDownloadState: Equatable, Sendable {
    case idle
    case downloading(received: Int64, total: Int64)
    case verifying
    case preparing
    case failed(String)
}

/// Models on disk and the one download at a time. Nothing is downloaded until `download(_:userAgreed:)` is called with a yes.
@MainActor @Observable
final class MusicKaraokeModelManager {
    private(set) var installed: [MusicKaraokeInstalledModel] = []
    private(set) var state: MusicKaraokeDownloadState = .idle
    private(set) var downloadingID: String?
    let catalog: [MusicKaraokeModelEntry]
    let directory: URL
    /// The app's resource folder, where an included model lives. Nil in tools that have no bundle.
    let bundledResources: URL?

    @ObservationIgnored private let downloader: MusicKaraokeFileDownloading
    /// Turns the downloaded file into something Core ML loads, writing it to the given destination.
    @ObservationIgnored private let compile: @Sendable (URL, URL) async throws -> Void
    @ObservationIgnored private var task: Task<Void, Never>?

    init(directory: URL = MusicKaraokeModelManager.defaultDirectory,
         catalog: [MusicKaraokeModelEntry] = MusicKaraokeModelCatalog.entries,
         downloader: MusicKaraokeFileDownloading = MusicKaraokeURLSessionDownloader(),
         bundledResources: URL? = Bundle.main.resourceURL,
         compile: @escaping @Sendable (URL, URL) async throws -> Void = { try await MusicCoreMLStemModel.compile($0, to: $1) }) {
        self.directory = directory; self.catalog = catalog; self.downloader = downloader; self.compile = compile
        self.bundledResources = bundledResources
        reload()
    }

    static var defaultDirectory: URL {
        MusicKaraokeCacheLocation.root.appendingPathComponent("models", isDirectory: true)
    }

    private var manifestURL: URL { directory.appendingPathComponent("installed.json") }

    var isDownloading: Bool { task != nil }
    var hasCatalog: Bool { !catalog.isEmpty }

    func entry(_ id: String) -> MusicKaraokeModelEntry? { catalog.first { $0.id == id } }
    func installedModel(_ id: String?) -> MusicKaraokeInstalledModel? { id.flatMap { i in installed.first { $0.id == i } } }
    func isInstalled(_ id: String) -> Bool { installedModel(id) != nil }
    func compiledURL(for m: MusicKaraokeInstalledModel) -> URL {
        if m.isBundled == true, let base = bundledResources {
            return base.appendingPathComponent(MusicKaraokeBundledModels.folderName, isDirectory: true).appendingPathComponent(m.compiledName, isDirectory: true)
        }
        return directory.appendingPathComponent(m.compiledName, isDirectory: true)
    }

    /// The model that is part of the app, when this build has one.
    var bundledModel: MusicKaraokeInstalledModel? { installed.first { $0.isBundled == true } }

    /// The model to run: the chosen one, else one of the chosen quality, else the one included in the app.
    func resolve(modelID: String?, tier: MusicKaraokeTier) -> MusicKaraokeInstalledModel? {
        installedModel(modelID) ?? installed.first(where: { $0.tier == tier }) ?? bundledModel
    }

    /// What the person is shown before agreeing.
    func disclosure(for entry: MusicKaraokeModelEntry) -> (title: String, size: String, license: String, host: String) {
        (entry.name, ByteCountFormatter.string(fromByteCount: entry.sizeBytes, countStyle: .file),
         entry.licenseName + "\n\n" + entry.licenseText, entry.url.host ?? "")
    }

    func reload() {
        let included = MusicKaraokeBundledModels.found(in: bundledResources)
        guard let data = try? Data(contentsOf: manifestURL), let list = try? JSONDecoder().decode([MusicKaraokeInstalledModel].self, from: data) else { installed = included; return }
        // A model whose compiled folder is gone is not installed.
        installed = included + list.filter { $0.isBundled != true && FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.compiledName).path) }
    }

    private func saveManifest() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(installed.filter { $0.isBundled != true }) { try? d.write(to: manifestURL, options: .atomic) }
    }

    /// Downloads, verifies size and SHA-256, compiles and installs. Does nothing unless `userAgreed` is true.
    func download(_ entry: MusicKaraokeModelEntry, userAgreed: Bool) {
        guard userAgreed, task == nil, entry.url.scheme?.lowercased() == "https" else { return }
        downloadingID = entry.id
        state = .downloading(received: 0, total: entry.sizeBytes)
        let dir = directory, downloader = self.downloader, compile = self.compile
        let me = self
        task = Task { [weak self] in
            let part = dir.appendingPathComponent(entry.id + ".part")
            let raw = dir.appendingPathComponent(entry.id + ".mlmodel")
            let compiledName = entry.id + ".mlmodelc"
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: part)
                try await downloader.download(from: entry.url, to: part) { got, total in
                    Task { @MainActor in me.state = .downloading(received: got, total: total > 0 ? total : entry.sizeBytes) }
                }
                self?.state = .verifying
                do { try MusicKaraokeIntegrity.verify(file: part, size: entry.sizeBytes, sha256: entry.sha256) }
                catch { try? FileManager.default.removeItem(at: part); throw error }
                try? FileManager.default.removeItem(at: raw)
                try FileManager.default.moveItem(at: part, to: raw)
                self?.state = .preparing
                try await compile(raw, dir.appendingPathComponent(compiledName, isDirectory: true))
                try? FileManager.default.removeItem(at: raw)
                self?.finishInstall(entry, compiledName: compiledName)
            } catch {
                try? FileManager.default.removeItem(at: part); try? FileManager.default.removeItem(at: raw)
                self?.failInstall(error)
            }
        }
    }

    private func finishInstall(_ e: MusicKaraokeModelEntry, compiledName: String) {
        installed.removeAll { $0.id == e.id }
        installed.append(MusicKaraokeInstalledModel(id: e.id, name: e.name, tier: e.tier, compiledName: compiledName, sizeBytes: e.sizeBytes, layout: e.layout))
        saveManifest()
        task = nil; downloadingID = nil; state = .idle
    }

    private func failInstall(_ error: Error) {
        task = nil; downloadingID = nil
        if error is CancellationError { state = .idle; return }
        switch error {
        case let e as MusicKaraokeIntegrityError where e != .unreadable:
            state = .failed("The downloaded file did not match what was expected. Try again.")
        case is URLError:
            state = .failed("The download failed. Check your connection and try again.")
        default:
            state = .failed("Couldn't save the model. Check free disk space and try again.")
        }
    }

    func cancelDownload() { task?.cancel() }
    func dismissError() { if case .failed = state { state = .idle } }

    /// Removes a model and its files. Refused while it downloads.
    @discardableResult
    func delete(_ id: String) -> Bool {
        guard downloadingID != id, let m = installedModel(id), m.isBundled != true else { return false }
        try? FileManager.default.removeItem(at: compiledURL(for: m))
        installed.removeAll { $0.id == id }
        saveManifest()
        return true
    }
}

/// Where karaoke keeps its files.
enum MusicKaraokeCacheLocation {
    static var root: URL { MusicStorage.subfolder("karaoke") }
    static var songs: URL { root.appendingPathComponent("songs", isDirectory: true) }
}
