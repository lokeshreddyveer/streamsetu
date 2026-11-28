import Foundation
import Observation

struct MusicDownloadItem: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable { case queued, resolving, downloading, paused, done, failed(String) }
    var track: MusicTrack
    var state: State = .queued
    var progress: Double = 0
    var bytes: Int64 = 0
    var fileName: String?
    /// Plain-English remark shown with a finished item, for example that tags could not be written.
    var note: String?
    var id: String { track.uid }
}

/// Saved next to each audio file so the list can be rebuilt from the folder alone after a relaunch.
private struct DownloadSidecar: Codable {
    var track: MusicTrack
    var fileName: String
    var bytes: Int64
    var savedAt: Date
}

struct MusicDownloadFailure: Error, Sendable {
    var message: String
    var resumeData: Data?
}

/// Receives URLSession callbacks on its own queue. The temporary file must be moved before the callback returns, so it is moved here into a
/// staging file inside the downloads folder (same volume, so the final move is a rename).
final class MusicDownloadBridge: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let staging: URL
    private let onProgress: @Sendable (Int, Int64, Int64) -> Void
    private let onFinished: @Sendable (Int, Result<URL, MusicDownloadFailure>) -> Void

    init(staging: URL, onProgress: @escaping @Sendable (Int, Int64, Int64) -> Void,
         onFinished: @escaping @Sendable (Int, Result<URL, MusicDownloadFailure>) -> Void) {
        self.staging = staging; self.onProgress = onProgress; self.onFinished = onFinished
    }

    /// A redirect to a private address is not followed, and another origin gets the request without its logins.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(MusicTransfer.redirect(request, after: task))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(downloadTask.taskIdentifier, totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let id = downloadTask.taskIdentifier
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            onFinished(id, .failure(MusicDownloadFailure(message: "The server answered \(http.statusCode).", resumeData: nil)))
            return
        }
        let staged = staging.appendingPathComponent(".partial-" + UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: staged)
            onFinished(id, .success(staged))
        } catch {
            onFinished(id, .failure(MusicDownloadFailure(message: "Could not save the file.", resumeData: nil)))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let ns = error as NSError
        onFinished(task.taskIdentifier, .failure(MusicDownloadFailure(
            message: ns.code == NSURLErrorCancelled ? "Cancelled." : ns.localizedDescription,
            resumeData: ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data)))
    }
}

/// Offline copies of tracks. Two downloads run at a time; each one resolves its stream through the resolver, saves into the downloads folder
/// under "Artist - Title", and writes a sidecar file so the list survives a relaunch. The player prefers a downloaded copy when one exists.
@MainActor @Observable
final class MusicDownloads {
    static let maxConcurrent = 2
    /// A download is refused when less than this is free, so the disk is never filled to the brim.
    static let minimumFreeBytes: Int64 = 50 * 1024 * 1024
    private static let sidecarSuffix = ".track.json"

    private(set) var items: [MusicDownloadItem] = []
    let directory: URL
    /// Set by the hub so downloads follow the quality setting.
    @ObservationIgnored var qualityProvider: () -> MusicQuality = { .high }
    /// Set by the hub from the "tag downloads" setting.
    @ObservationIgnored var tagsEnabled: () -> Bool = { true }
    /// Used only to fetch the cover image from the address the person's own provider gave for it.
    @ObservationIgnored var tagHTTP = MusicHTTP()
    /// A complete copy of the song in the audio cache, saved when fetching fails. Set by the hub; nil means no cache.
    @ObservationIgnored var cachedCopy: (MusicTrack) -> URL? = { _ in nil }
    /// Reads one byte range; replaced in tests.
    @ObservationIgnored var rangeFetch: MusicRangedDownloader.Fetch = MusicRangedDownloader.live

    @ObservationIgnored private let resolver: MusicStreamResolver
    @ObservationIgnored private let freeSpace: @Sendable (URL) -> Int64?
    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private var bridge: MusicDownloadBridge?
    @ObservationIgnored private var tasks: [String: URLSessionDownloadTask] = [:]
    @ObservationIgnored private var taskItems: [Int: String] = [:]
    @ObservationIgnored private var resolveTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var resumeData: [String: Data] = [:]
    @ObservationIgnored private var extensions: [String: String] = [:]
    @ObservationIgnored private var streamKinds: [String: (container: String, codec: String)] = [:]
    @ObservationIgnored private var spaceChecked: Set<String> = []

    init(resolver: MusicStreamResolver, directory: URL,
         freeSpace: @escaping @Sendable (URL) -> Int64? = MusicDownloads.availableBytes) {
        self.resolver = resolver
        self.directory = directory
        self.freeSpace = freeSpace
        MusicStorage.ensureUnbacked(directory)
        rebuildIndex()
    }

    // MARK: public

    func enqueue(_ t: MusicTrack) {
        // SoundCloud uploads are streamed only, never saved.
        if t.providerID == SoundCloudProvider.providerID { MusicDebugLog.log("downloads", "skipped a SoundCloud track: streaming only"); return }
        if let i = items.firstIndex(where: { $0.id == t.uid }) {
            switch items[i].state {
            case .done, .queued, .resolving, .downloading: return
            case .paused, .failed: items[i].state = .queued; resolver.forgive(t)
            }
        } else {
            items.append(MusicDownloadItem(track: t))
        }
        pump()
    }

    func isDownloaded(_ t: MusicTrack) -> Bool { localURL(for: t) != nil }

    func localURL(for t: MusicTrack) -> URL? {
        guard let item = items.first(where: { $0.id == t.uid && $0.state == .done }), let name = item.fileName else { return nil }
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Stops a download that is not finished and drops it from the list.
    func cancel(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].state != .done else { return }
        stopTransfer(id)
        resumeData[id] = nil
        items.remove(at: i)
        pump()
    }

    /// Stops a running download but keeps what was received, to continue later.
    func pause(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        switch items[i].state {
        case .queued, .resolving: stopTransfer(id); items[i].state = .paused
        case .downloading:
            items[i].state = .paused
            resolveTasks[id]?.cancel(); resolveTasks[id] = nil
            if let task = tasks[id] {
                tasks[id] = nil; taskItems[task.taskIdentifier] = nil
                task.cancel(byProducingResumeData: { [weak self] data in
                    Task { @MainActor [weak self] in if let data { self?.resumeData[id] = data } }
                })
            }
        default: return
        }
        pump()
    }

    func resume(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        switch items[i].state { case .paused, .failed: resolver.forgive(items[i].track); items[i].state = .queued; pump(); default: return }
    }

    /// Removes the item; a finished one also loses its audio file and sidecar.
    func remove(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        stopTransfer(id)
        if let name = items[i].fileName {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name + Self.sidecarSuffix))
        }
        resumeData[id] = nil
        items.remove(at: i)
        pump()
    }

    func removeAll() { for id in items.map(\.id) { remove(id) } }

    var totalBytes: Int64 { items.filter { $0.state == .done }.reduce(0) { $0 + $1.bytes } }

    // MARK: naming (pure)

    /// "Artist - Title.ext" with anything a file system dislikes removed.
    nonisolated static func fileName(for track: MusicTrack, ext: String) -> String {
        let artist = sanitize(track.artists.first?.name ?? "")
        let title = sanitize(track.title)
        let base = [artist, title].filter { !$0.isEmpty }.joined(separator: " - ")
        let cleanExt = ext.lowercased().filter { $0.isLetter || $0.isNumber }
        return (base.isEmpty ? "Track" : base) + "." + (cleanExt.isEmpty ? "m4a" : cleanExt)
    }

    nonisolated static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters).union(.newlines)
        var out = s.unicodeScalars.map { bad.contains($0) ? " " : String($0) }.joined()
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        out = out.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        if out.count > 100 { out = String(out.prefix(100)).trimmingCharacters(in: .whitespaces) }
        return out
    }

    nonisolated static func fileExtension(for stream: MusicStream) -> String {
        let known = ["m4a", "mp3", "aac", "flac", "opus", "ogg", "wav", "webm", "mp4", "alac"]
        let c = stream.container.lowercased()
        if known.contains(c) { return c }
        if let url = URL(string: stream.url), known.contains(url.pathExtension.lowercased()) { return url.pathExtension.lowercased() }
        switch stream.codec.lowercased() {
        case "aac", "mp4a": return "m4a"
        case "mp3": return "mp3"
        case "flac": return "flac"
        case "opus": return "opus"
        default: return "m4a"
        }
    }

    nonisolated static func availableBytes(_ url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: running

    private func activeCount() -> Int { items.filter { $0.state == .resolving || $0.state == .downloading }.count }

    private func pump() {
        while activeCount() < Self.maxConcurrent, let i = items.firstIndex(where: { $0.state == .queued }) {
            begin(items[i].id)
        }
    }

    private func begin(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].state = .resolving
        let track = items[i].track
        if let data = resumeData[id] {
            startTransfer(id, request: nil, resumeData: data)
            return
        }
        resolveTasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await resolver.resolve(track, quality: qualityProvider())
                if Task.isCancelled { return }
                self.startTransfer(id, stream: stream)
            } catch {
                if Task.isCancelled { return }
                self.fail(id, error.localizedDescription)
            }
        }
    }

    private func startTransfer(_ id: String, stream: MusicStream) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].state == .resolving else { return }
        resolveTasks[id] = nil
        guard stream.proto == .progressive, let url = URL(string: stream.url), MusicTransfer.isAllowed(url) else {
            fail(id, "This source cannot be saved for offline listening."); return
        }
        extensions[id] = Self.fileExtension(for: stream)
        streamKinds[id] = (stream.container, stream.codec)
        // YouTube's media hosts only serve bounded windows reliably, and their addresses expire: those files come down in ranges.
        if MusicProxyPolicy.isGoogleVideo(url) { startRanged(id, stream: stream, url: url); return }
        var request = URLRequest(url: url)
        for (k, v) in stream.headers { request.setValue(v, forHTTPHeaderField: k) }
        startTransfer(id, request: request, resumeData: nil)
    }

    private func startTransfer(_ id: String, request: URLRequest?, resumeData data: Data?) {
        guard items.contains(where: { $0.id == id }) else { return }
        if let free = freeSpace(directory), free < Self.minimumFreeBytes { fail(id, "Not enough free space."); return }
        let task: URLSessionDownloadTask
        if let data { task = makeSession().downloadTask(withResumeData: data); resumeData[id] = nil }
        else if let request { task = makeSession().downloadTask(with: request) }
        else { fail(id, "Nothing to download."); return }
        tasks[id] = task
        taskItems[task.taskIdentifier] = id
        setState(id, .downloading)
        task.resume()
    }

    private func startRanged(_ id: String, stream: MusicStream, url: URL) {
        guard let track = items.first(where: { $0.id == id })?.track else { return }
        if let free = freeSpace(directory), free < Self.minimumFreeBytes { fail(id, "Not enough free space."); return }
        setState(id, .downloading)
        let staged = directory.appendingPathComponent(".partial-" + UUID().uuidString)
        let resolver = self.resolver
        let quality = qualityProvider()
        let headers = MusicProxyPolicy.headers(for: url, base: stream.headers)
        let fetch = rangeFetch
        // The address that is in use now, so a re-lookup drops exactly the one that stopped working (the first one, then each fresh one after it).
        let inUse = MusicAddressInUse(stream)
        let onProgress: @Sendable (Int64, Int64) -> Void = { [weak self] written, total in
            Task { @MainActor [weak self] in self?.rangedProgress(id, written, total) }
        }
        resolveTasks[id] = Task { [weak self] in
            do {
                let out = try await MusicRangedDownloader.run(
                    source: .init(url: url, headers: headers, total: nil), destination: staged, fetch: fetch,
                    reresolve: {
                        await resolver.evict(track, stream: inUse.value)
                        guard let fresh = try? await resolver.resolve(track, quality: quality), let u = URL(string: fresh.url) else { return nil }
                        inUse.value = fresh
                        let h = MusicProxyPolicy.headers(for: u, base: fresh.headers)
                        guard let a = try? await fetch(u, h, 0...0) else { return nil }
                        return .init(url: u, headers: h, total: a.total)
                    },
                    progress: onProgress)
                if Task.isCancelled { try? FileManager.default.removeItem(at: staged); return }
                self?.rangedFinished(id, staged: staged, firstBytes: out.firstBytes)
            } catch {
                try? FileManager.default.removeItem(at: staged)
                if Task.isCancelled { return }
                self?.rangedFailed(id, error: error)
            }
        }
    }

    private func rangedProgress(_ id: String, _ written: Int64, _ total: Int64) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].bytes = written
        items[i].progress = total > 0 ? min(1, Double(written) / Double(total)) : 0
    }

    private func rangedFinished(_ id: String, staged: URL, firstBytes: Data) {
        resolveTasks[id] = nil
        if let ext = MusicContainerSniff.fileExtension(firstBytes: firstBytes) { extensions[id] = ext }
        tagThenFinalize(id, staged: staged)
    }

    /// Fetching failed: a complete copy from the audio cache is saved instead when there is one.
    private func rangedFailed(_ id: String, error: Error) {
        resolveTasks[id] = nil
        if let track = items.first(where: { $0.id == id })?.track, let cached = cachedCopy(track) {
            let staged = directory.appendingPathComponent(".partial-" + UUID().uuidString)
            if (try? FileManager.default.copyItem(at: cached, to: staged)) != nil {
                if let h = try? FileHandle(forReadingFrom: staged), let d = try? h.read(upToCount: 512) {
                    if let ext = MusicContainerSniff.fileExtension(firstBytes: d) { extensions[id] = ext }
                    try? h.close()
                }
                tagThenFinalize(id, staged: staged)
                return
            }
        }
        fail(id, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    private func makeSession() -> URLSession {
        if let session { return session }
        let b = MusicDownloadBridge(
            staging: directory,
            onProgress: { [weak self] taskID, written, expected in
                Task { @MainActor [weak self] in self?.progress(taskID, written, expected) }
            },
            onFinished: { [weak self] taskID, result in
                Task { @MainActor [weak self] in self?.finished(taskID, result) }
            })
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        let s = MusicTransfer.session(configuration: config, delegate: b)
        bridge = b; session = s
        return s
    }

    private func progress(_ taskID: Int, _ written: Int64, _ expected: Int64) {
        guard let id = taskItems[taskID], let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].bytes = written
        if expected > 0 {
            items[i].progress = min(1, Double(written) / Double(expected))
            if spaceChecked.insert(id).inserted, let free = freeSpace(directory), free < expected + Self.minimumFreeBytes {
                stopTransfer(id); fail(id, "Not enough free space.")
            }
        }
    }

    private func finished(_ taskID: Int, _ result: Result<URL, MusicDownloadFailure>) {
        guard let id = taskItems[taskID] else {
            // Already paused or cancelled: a leftover staging file is discarded.
            if case .success(let staged) = result { try? FileManager.default.removeItem(at: staged) }
            return
        }
        taskItems[taskID] = nil; tasks[id] = nil; spaceChecked.remove(id)
        switch result {
        case .success(let staged): tagThenFinalize(id, staged: staged)
        case .failure(let f):
            if let d = f.resumeData { resumeData[id] = d }
            fail(id, f.message)
        }
    }

    /// Writes the tags into the staged file before it is moved into place. Tagging is best effort: any problem leaves the file untagged
    /// and records a note, and the download still succeeds.
    private func tagThenFinalize(_ id: String, staged: URL) {
        guard tagsEnabled(), let track = items.first(where: { $0.id == id })?.track else { finalize(id, staged: staged, note: nil); return }
        let kind = streamKinds[id] ?? ("", "")
        let http = tagHTTP
        Task { [weak self] in
            let cover = await MusicTagWriter.fetchCover(for: track, http: http)
            let result = await MusicTagWriter.write(MusicTagInfo(track: track, coverJPEG: cover), to: staged,
                                                    container: kind.0, codec: kind.1)
            guard let self else { try? FileManager.default.removeItem(at: staged); return }
            let note: String?
            switch result {
            case .tagged: note = nil
            case .unsupportedFormat: note = "Saved without tags: this audio format cannot hold them."
            case .failed: note = "Saved without tags: they could not be written."
            }
            self.finalize(id, staged: staged, note: note)
        }
    }

    private func finalize(_ id: String, staged: URL, note: String?) {
        streamKinds[id] = nil
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].state == .downloading else { try? FileManager.default.removeItem(at: staged); return }
        let track = items[i].track
        let fm = FileManager.default
        if let h = try? FileHandle(forReadingFrom: staged) {
            if let d = try? h.read(upToCount: 512), let real = MusicContainerSniff.fileExtension(firstBytes: d) { extensions[id] = real }
            try? h.close()
        }
        let name = freeName(for: track, ext: extensions[id] ?? "m4a")
        let dest = directory.appendingPathComponent(name)
        do {
            if fm.fileExists(atPath: dest.path) { _ = try fm.replaceItemAt(dest, withItemAt: staged) } else { try fm.moveItem(at: staged, to: dest) }
            let size = ((try? fm.attributesOfItem(atPath: dest.path))?[.size] as? NSNumber)?.int64Value ?? items[i].bytes
            let sidecar = DownloadSidecar(track: track, fileName: name, bytes: size, savedAt: Date())
            let data = try JSONEncoder().encode(sidecar)
            try data.write(to: directory.appendingPathComponent(name + Self.sidecarSuffix), options: .atomic)
            items[i].fileName = name; items[i].note = note; items[i].bytes = size; items[i].progress = 1; items[i].state = .done
        } catch {
            try? fm.removeItem(at: staged)
            fail(id, "Could not save the file.")
            return
        }
        extensions[id] = nil
        pump()
    }

    /// A file name that does not collide with a different track's file.
    private func freeName(for track: MusicTrack, ext: String) -> String {
        let first = Self.fileName(for: track, ext: ext)
        let taken = Set(items.filter { $0.id != track.uid }.compactMap(\.fileName))
        if !taken.contains(first) { return first }
        let stem = (first as NSString).deletingPathExtension
        for n in 2...99 {
            let candidate = "\(stem) (\(n)).\(ext)"
            if !taken.contains(candidate) { return candidate }
        }
        return stem + " " + UUID().uuidString.prefix(6) + "." + ext
    }

    private func fail(_ id: String, _ message: String) {
        if let track = items.first(where: { $0.id == id })?.track {
            MusicPlaybackLog.shared.recordFailure(MusicFailureRecord(at: Date(), track: track.title, provider: track.providerID, stage: .download, reason: message,
                                                                    decision: "download stopped; press resume to try again with a fresh lookup"))
        }
        setState(id, .failed(message))
        resolveTasks[id]?.cancel(); resolveTasks[id] = nil
        pump()
    }

    private func setState(_ id: String, _ s: MusicDownloadItem.State) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].state = s }
    }

    private func stopTransfer(_ id: String) {
        resolveTasks[id]?.cancel(); resolveTasks[id] = nil
        if let t = tasks[id] { taskItems[t.taskIdentifier] = nil; t.cancel() }
        tasks[id] = nil
    }

    // MARK: index

    /// The list is whatever the folder holds: each audio file has a sidecar, and a sidecar without its audio is deleted.
    private func rebuildIndex() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        var found: [MusicDownloadItem] = []
        for n in names {
            if n.hasPrefix(".partial-") { try? fm.removeItem(at: directory.appendingPathComponent(n)); continue }
            guard n.hasSuffix(Self.sidecarSuffix) else { continue }
            let sidecarURL = directory.appendingPathComponent(n)
            guard let data = try? Data(contentsOf: sidecarURL), let s = try? JSONDecoder().decode(DownloadSidecar.self, from: data),
                  fm.fileExists(atPath: directory.appendingPathComponent(s.fileName).path) else {
                try? fm.removeItem(at: sidecarURL); continue
            }
            found.append(MusicDownloadItem(track: s.track, state: .done, progress: 1, bytes: s.bytes, fileName: s.fileName))
        }
        items = found.sorted { $0.track.title.localizedCaseInsensitiveCompare($1.track.title) == .orderedAscending }
    }
}

/// The stream address a ranged download is using now (see `startRanged`).
final class MusicAddressInUse: @unchecked Sendable {
    private let lock = NSLock()
    private var current: MusicStream
    init(_ s: MusicStream) { current = s }
    var value: MusicStream { get { lock.withLock { current } } set { lock.withLock { current = newValue } } }
}
