import Foundation
import Observation

/// Saves movies and episodes on this device so they play without a connection. One download runs at a time (a playlist that allows one connection
/// cannot also stream), none runs while something is playing (a download would take the connection a stream needs), and a download that was
/// interrupted carries on from where it stopped. The stream address is asked of the playlist when a download starts and is never stored or shown.
@MainActor @Observable
final class DownloadService: NSObject, URLSessionDownloadDelegate {
    private(set) var records: [DownloadRecord] = []

    @ObservationIgnored private let db: DatabaseManager
    @ObservationIgnored private let catalog: SQLiteCatalogRepository
    @ObservationIgnored private let resolver: StreamResolver
    @ObservationIgnored private let busy: @Sendable () async -> Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private var tasks: [String: URLSessionDownloadTask] = [:]
    @ObservationIgnored private var heldForPlayback: Set<String> = []
    @ObservationIgnored private var starting: Set<String> = []
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var lastSaved: [String: Int64] = [:]
    @ObservationIgnored private var sweeps = 0

    /// Where the files are kept. Outside the backup: they can be big and can always be fetched again.
    nonisolated static var folder: URL {
        var url = StorageService.ensure(StorageService.applicationSupport.appendingPathComponent("Downloads", isDirectory: true))
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }

    /// Downloads over Wi-Fi or a cable only (the default); off lets a phone use mobile data too.
    var wifiOnly: Bool {
        get { defaults.object(forKey: "downloads.wifiOnly") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "downloads.wifiOnly") }
    }

    /// Removes a saved movie or episode once it has been watched to the end, so a phone or Mac does not fill up. Off by default.
    var deleteWhenWatched: Bool {
        get { defaults.bool(forKey: "downloads.deleteWatched") }
        set { defaults.set(newValue, forKey: "downloads.deleteWatched") }
    }

    init(db: DatabaseManager, catalog: SQLiteCatalogRepository, resolver: StreamResolver, defaults: UserDefaults = .standard, busy: @escaping @Sendable () async -> Bool) {
        self.db = db; self.catalog = catalog; self.resolver = resolver; self.defaults = defaults; self.busy = busy
        super.init()
        let config: URLSessionConfiguration
        #if os(iOS)
        config = .background(withIdentifier: "app.streamsetu.downloads")          // keeps going when the app is not on screen
        config.sessionSendsLaunchEvents = true
        config.allowsExpensiveNetworkAccess = !wifiOnly
        config.allowsConstrainedNetworkAccess = !wifiOnly
        #else
        config = .default
        #endif
        config.timeoutIntervalForRequest = 60
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        records = (try? load()) ?? []
        // A download that was running when the app closed starts again; one the system kept going is picked up.
        session.getAllTasks { [weak self] found in
            let live = found.compactMap { $0 as? URLSessionDownloadTask }
            Task { @MainActor in self?.adopt(live) }
        }
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    // MARK: asking

    /// What to show on a movie's or series' poster: the most active download of the title (for a series, any of its episodes).
    func status(forTitle id: String) -> (state: DownloadRecord.State, fraction: Double)? {
        let mine = records.filter { $0.itemID == id || $0.seriesID == id }
        for state in [DownloadRecord.State.downloading, .queued, .paused, .failed, .done] {
            if let r = mine.first(where: { $0.state == state }) { return (state, r.fraction) }
        }
        return nil
    }

    func record(for itemID: String) -> DownloadRecord? { records.first { $0.itemID == itemID } }

    /// The saved file of a finished download, or nil.
    func localURL(for itemID: String) -> URL? {
        guard let r = record(for: itemID), r.state == .done, let name = r.fileName else { return nil }
        let url = Self.folder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The file for a finished download, from outside the main actor (the stream resolver asks from wherever playback starts).
    nonisolated static func savedFile(for itemID: String, in db: DatabaseManager) -> URL? {
        let row = try? db.read { c in try c.queryOne("SELECT file_name FROM downloads WHERE item_id=? AND state='done'", [itemID]) { $0.optString(0) } }
        guard let name = row ?? nil else { return nil }
        let url = folder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var totalBytes: Int64 { records.reduce(0) { $0 + ($1.state == .done ? $1.bytesTotal : $1.bytesDone) } }

    // MARK: adding and removing

    func enqueue(movie m: Movie) {
        guard record(for: m.id) == nil || record(for: m.id)?.state == .failed else { return }
        add(DownloadRecord(itemID: m.id, kind: .movie, sourceID: m.sourceID, seriesID: nil, title: m.title,
                           subtitle: [m.releaseYear.map(String.init), m.categoryName].compactMap { $0 }.joined(separator: " · "),
                           artworkURL: m.posterURL ?? m.backdropURL, fileName: nil, state: .queued, bytesDone: 0, bytesTotal: 0, addedAt: Date(), error: nil))
    }

    func enqueue(episode e: Episode, series s: Series) {
        guard record(for: e.id) == nil || record(for: e.id)?.state == .failed else { return }
        add(DownloadRecord(itemID: e.id, kind: .episode, sourceID: s.sourceID, seriesID: s.id, title: s.title,
                           subtitle: "S\(e.seasonNumber) E\(e.episodeNumber) · \(e.title)", artworkURL: e.imageURL ?? s.posterURL,
                           fileName: nil, state: .queued, bytesDone: 0, bytesTotal: 0, addedAt: Date(), error: nil))
    }

    func pause(_ itemID: String) {
        guard let task = tasks[itemID] else { setState(itemID, .paused); return }
        tasks[itemID] = nil
        task.cancel { [weak self] data in Task { @MainActor in self?.keepResumeData(data, for: itemID) } }
        setState(itemID, .paused)
    }

    func resume(_ itemID: String) {
        guard let r = record(for: itemID), r.state == .paused || r.state == .failed else { return }
        setState(itemID, .queued, error: nil)
        pump()
    }

    /// Stops a download if it is running, deletes what was saved, and forgets it.
    func remove(_ itemID: String) {
        tasks[itemID]?.cancel(); tasks[itemID] = nil
        heldForPlayback.remove(itemID)
        if let name = record(for: itemID)?.fileName { try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(name)) }
        try? FileManager.default.removeItem(at: resumeFile(itemID))
        try? db.write { try $0.execute("DELETE FROM downloads WHERE item_id=?", [itemID]) }
        records.removeAll { $0.itemID == itemID }
        pump()
    }

    func removeAll() { for r in records { remove(r.itemID) } }

    // MARK: the work

    private func add(_ r: DownloadRecord) {
        records.removeAll { $0.itemID == r.itemID }
        records.append(r)
        save(r)
        pump()
    }

    private func tick() async {
        let playing = await busy()
        if playing {
            for id in tasks.keys { heldForPlayback.insert(id); pause(id) }
        } else if !heldForPlayback.isEmpty {
            for id in heldForPlayback where record(for: id)?.state == .paused { setState(id, .queued) }
            heldForPlayback = []
        }
        if !playing { pump() }
        sweeps += 1
        if !playing, deleteWhenWatched, sweeps % 8 == 0 { sweepWatched() }
    }

    /// Deletes the finished downloads whose title has been watched to the end. Nothing is deleted while something plays.
    func sweepWatched() {
        let saved = records.filter { $0.state == .done }.map(\.itemID)
        guard !saved.isEmpty, let watched = try? db.read({ c in try c.query("SELECT item_id FROM watch_progress WHERE completed = 1", []) { $0.string(0) } }) else { return }
        let finished = Set(watched)
        for id in saved where finished.contains(id) { remove(id) }
    }

    /// Starts the oldest waiting download when none is running.
    private func pump() {
        guard tasks.isEmpty, starting.isEmpty, let next = records.filter({ $0.state == .queued }).min(by: { $0.addedAt < $1.addedAt }) else { return }
        starting.insert(next.itemID)
        Task { await begin(next) }
    }

    private func begin(_ r: DownloadRecord) async {
        defer { starting.remove(r.itemID) }
        do {
            let resumeData = try? Data(contentsOf: resumeFile(r.itemID))
            let task: URLSessionDownloadTask
            // The title is looked up again every time, also when carrying on from saved progress: if it has been removed, its folder locked or its playlist turned off since, nothing continues.
            var request = try await urlRequest(for: r)
            request.allowsExpensiveNetworkAccess = !wifiOnly
            if let resumeData, !resumeData.isEmpty { task = session.downloadTask(withResumeData: resumeData) }
            else { task = session.downloadTask(with: request) }
            task.taskDescription = r.itemID
            tasks[r.itemID] = task
            setState(r.itemID, .downloading, error: nil)
            task.resume()
        } catch {
            setState(r.itemID, .failed, error: (error as? LocalizedError)?.errorDescription ?? "This title could not be saved.")
            pump()
        }
    }

    private struct Unsavable: LocalizedError { let errorDescription: String? }

    private func urlRequest(for r: DownloadRecord) async throws -> URLRequest {
        var request: PlaybackRequest
        switch r.kind {
        case .movie:
            guard let m = try catalog.movie(id: r.itemID) else { throw Unsavable(errorDescription: "This movie is no longer in the library.") }
            request = try resolver.resolve(movie: m, resume: false, allowLocal: false)
        case .episode:
            guard let e = try catalog.episode(id: r.itemID), let s = try catalog.seriesItem(id: e.seriesID) else { throw Unsavable(errorDescription: "This episode is no longer in the library.") }
            request = try resolver.resolve(episode: e, series: s, resume: false, allowLocal: false)
        default: throw Unsavable(errorDescription: "Only movies and episodes can be saved.")
        }
        if request.url.scheme == PortalLink.scheme { request.url = try await resolver.finalURL(for: request.url, sourceID: r.sourceID) }
        if DownloadNaming.isStreamingList(request.url) { throw Unsavable(errorDescription: "This title streams in pieces and cannot be saved as one file.") }
        var out = URLRequest(url: request.url)
        for (k, v) in request.headers { out.setValue(v, forHTTPHeaderField: k) }
        if out.value(forHTTPHeaderField: "User-Agent") == nil { out.setValue("VLC/3.0.20 LibVLC/3.0.20", forHTTPHeaderField: "User-Agent") }
        return out
    }

    /// Picks up what the system kept going while the app was closed, and starts again what had no task left.
    private func adopt(_ found: [URLSessionDownloadTask]) {
        for t in found { if let id = t.taskDescription, record(for: id) != nil { tasks[id] = t } else { t.cancel() } }
        for r in records where r.state == .downloading && tasks[r.itemID] == nil { setState(r.itemID, .queued) }
        pump()
    }

    // MARK: results from the session (they arrive on the session's own queue)

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        Task { @MainActor in self.progress(id, done: totalBytesWritten, total: totalBytesExpectedToWrite) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        var name: String?; var failure: String?
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        if !(200..<300).contains(status) { failure = "The playlist refused the download (code \(status))." }
        else {
            let url = downloadTask.currentRequest?.url ?? downloadTask.originalRequest?.url ?? URL(fileURLWithPath: "/x.mp4")
            let file = DownloadNaming.fileName(itemID: id, url: url)
            let destination = Self.folder.appendingPathComponent(file)
            try? FileManager.default.removeItem(at: destination)
            do { try FileManager.default.moveItem(at: location, to: destination); name = file } catch { failure = "The file could not be saved on this device." }
        }
        let size = name.flatMap { (try? FileManager.default.attributesOfItem(atPath: Self.folder.appendingPathComponent($0).path)[.size] as? Int64) ?? nil } ?? 0
        Task { @MainActor in self.finished(id, fileName: name, size: size, failure: failure) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        let ns = error as NSError
        let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let message = ns.code == NSURLErrorNotConnectedToInternet || ns.code == NSURLErrorNetworkConnectionLost ? "The connection was lost." : CredentialRedactor.redact(ns.localizedDescription)
        let cancelled = ns.code == NSURLErrorCancelled
        Task { @MainActor in self.broke(id, cancelled: cancelled, resumeData: data, message: message) }
    }

    private func progress(_ id: String, done: Int64, total: Int64) {
        guard let i = records.firstIndex(where: { $0.itemID == id }) else { return }
        records[i].bytesDone = done
        if total > 0 { records[i].bytesTotal = total }
        if done - (lastSaved[id] ?? 0) > 8_000_000 { lastSaved[id] = done; save(records[i]) }
    }

    private func finished(_ id: String, fileName: String?, size: Int64, failure: String?) {
        tasks[id] = nil
        try? FileManager.default.removeItem(at: resumeFile(id))
        guard let i = records.firstIndex(where: { $0.itemID == id }) else { return }
        if let fileName {
            records[i].fileName = fileName; records[i].state = .done; records[i].bytesTotal = max(size, records[i].bytesTotal); records[i].bytesDone = records[i].bytesTotal; records[i].error = nil
        } else { records[i].state = .failed; records[i].error = failure }
        save(records[i])
        pump()
    }

    private func broke(_ id: String, cancelled: Bool, resumeData: Data?, message: String) {
        guard let i = records.firstIndex(where: { $0.itemID == id }) else { return }
        if cancelled && records[i].state != .downloading { return }            // paused or removed on purpose
        tasks[id] = nil
        if let resumeData { keepResumeData(resumeData, for: id); records[i].state = .paused; records[i].error = "Interrupted. Resume to carry on." }
        else { records[i].state = .failed; records[i].error = message }
        save(records[i])
        pump()
    }

    private func keepResumeData(_ data: Data?, for id: String) {
        guard let data, !data.isEmpty else { return }
        try? data.write(to: resumeFile(id), options: .atomic)
    }

    private func resumeFile(_ id: String) -> URL { Self.folder.appendingPathComponent(DownloadNaming.fileName(itemID: id, url: URL(fileURLWithPath: "/x.mp4")) + ".resume") }

    private func setState(_ id: String, _ state: DownloadRecord.State, error: String?? = nil) {
        guard let i = records.firstIndex(where: { $0.itemID == id }) else { return }
        records[i].state = state
        if let error { records[i].error = error }
        save(records[i])
    }

    // MARK: the table

    private func save(_ r: DownloadRecord) {
        try? db.write { c in
            try c.execute("""
                INSERT OR REPLACE INTO downloads(item_id, kind, source_id, series_id, title, subtitle, artwork_url, file_name, state, bytes_done, bytes_total, added_at, error)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [r.itemID, r.kind.rawValue, r.sourceID, r.seriesID, r.title, r.subtitle, r.artworkURL, r.fileName, r.state.rawValue, Int(r.bytesDone), Int(r.bytesTotal), r.addedAt, r.error])
        }
    }

    private func load() throws -> [DownloadRecord] {
        try db.read { c in
            try c.query("SELECT item_id, kind, source_id, series_id, title, subtitle, artwork_url, file_name, state, bytes_done, bytes_total, added_at, error FROM downloads ORDER BY added_at") { r in
                DownloadRecord(itemID: r.string(0), kind: ContentKind(rawValue: r.string(1)) ?? .movie, sourceID: r.uuid(2) ?? UUID(), seriesID: r.optString(3), title: r.string(4),
                               subtitle: r.optString(5), artworkURL: r.optString(6), fileName: r.optString(7), state: DownloadRecord.State(rawValue: r.string(8)) ?? .failed,
                               bytesDone: Int64(r.int(9)), bytesTotal: Int64(r.int(10)), addedAt: r.date(11), error: r.optString(12))
            }
        }
    }
}
