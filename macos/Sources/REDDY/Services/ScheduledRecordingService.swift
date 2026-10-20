#if os(macOS)
import Foundation
import Observation

struct ScheduledRecording: Identifiable, Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case scheduled, recording, done, failed, missed }
    var id = UUID()
    var channelID: String
    var channelName: String
    var title: String
    var start: Date
    var end: Date
    var state: State = .scheduled
    var detail: String?
}

/// Records a live programme at its time: the person presses Record in the guide, and while the app is open the Mac keeps itself awake, opens the channel's stream at the
/// start and writes it to a file in Recordings until the programme ends (a minute of padding on each side). It needs a connection of its own, so a provider that allows only
/// one stream cannot record while something else plays. The app has to be open at that time.
@MainActor @Observable
final class ScheduledRecordingService {
    private(set) var items: [ScheduledRecording] = []

    typealias Find = @Sendable (String) throws -> Channel?
    typealias Resolve = @Sendable (Channel) throws -> PlaybackRequest
    private let find: Find
    private let resolve: Resolve
    private let defaults: UserDefaults
    private let folder: URL
    private let padding: TimeInterval
    private let key = "recordings.scheduled"
    private var tick: Task<Void, Never>?
    private var running: [UUID: Task<Void, Never>] = [:]

    init(find: @escaping Find, resolve: @escaping Resolve, defaults: UserDefaults, folder: URL = Recordings.folder, padding: TimeInterval = 60) {
        self.find = find; self.resolve = resolve; self.defaults = defaults; self.folder = folder; self.padding = padding
        items = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([ScheduledRecording].self, from: $0) } ?? []
        // anything that was recording when the app closed did not finish
        for i in items.indices where items[i].state == .recording { items[i].state = .failed; items[i].detail = "The app was closed during the recording." }
        save()
    }

    func start() {
        tick?.cancel()
        tick = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    private func save() { defaults.set(try? JSONEncoder().encode(items), forKey: key) }

    func isScheduled(channelID: String, start: Date) -> Bool { items.contains { $0.channelID == channelID && $0.start == start && $0.state == .scheduled } }

    @discardableResult
    func schedule(program: EPGProgram, channel: Channel) -> Bool {
        guard program.end > Date(), !isScheduled(channelID: channel.id, start: program.start) else { return false }
        items.append(ScheduledRecording(channelID: channel.id, channelName: channel.name, title: program.title, start: program.start, end: program.end))
        items.sort { $0.start < $1.start }
        save()
        return true
    }

    func cancel(channelID: String, start: Date) {
        guard let i = items.firstIndex(where: { $0.channelID == channelID && $0.start == start && $0.state == .scheduled }) else { return }
        items.remove(at: i); save()
    }

    func remove(_ id: UUID) {
        running[id]?.cancel()
        items.removeAll { $0.id == id }; save()
    }

    func waitForRecordings() async { for t in Array(running.values) { await t.value } }

    func clearFinished() { items.removeAll { [.done, .failed, .missed].contains($0.state) }; save() }

    /// Looks at what is due. The timer calls it every 15 seconds; tests call it directly.
    func check() async {
        let now = Date()
        for i in items.indices where items[i].state == .scheduled {
            if items[i].end <= now { items[i].state = .missed; items[i].detail = "The app was not open at that time."; save(); continue }
            if items[i].start.addingTimeInterval(-padding) <= now { begin(items[i].id) }
        }
    }

    private func begin(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }), running[id] == nil else { return }
        items[i].state = .recording; save()
        let job = items[i]
        let (find, resolve, folder, padding) = (self.find, self.resolve, self.folder, self.padding)
        running[id] = Task { [weak self] in
            let outcome = await Self.capture(job, find: find, resolve: resolve, folder: folder, padding: padding)
            await MainActor.run {
                guard let self, let j = self.items.firstIndex(where: { $0.id == id }) else { return }
                switch outcome {
                case .success: self.items[j].state = .done; self.items[j].detail = nil
                case .failure(let e): self.items[j].state = .failed; self.items[j].detail = e.localizedDescription
                }
                self.running[id] = nil; self.save()
            }
        }
    }

    private struct CaptureError: LocalizedError { let errorDescription: String? }

    /// Writes the stream to a file until the programme's end plus padding.
    nonisolated private static func capture(_ job: ScheduledRecording, find: Find, resolve: Resolve, folder: URL, padding: TimeInterval) async -> Result<Void, Error> {
        let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Recording \(job.title)")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        do {
            guard let channel = try find(job.channelID) else { return .failure(CaptureError(errorDescription: "The channel is no longer in the library.")) }
            let request = try resolve(channel)
            var req = URLRequest(url: request.url, timeoutInterval: 30)
            for (k, v) in request.headers { req.setValue(v, forHTTPHeaderField: k) }
            let file = folder.appendingPathComponent(Recordings.fileName(channel: "\(job.channelName) - \(job.title)", at: Date()))
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            let stop = job.end.addingTimeInterval(padding)
            let writer = StreamWriter(handle: handle, until: stop)
            let session = URLSession(configuration: .ephemeral, delegate: writer, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let task = session.dataTask(with: req)
            task.resume()
            let result = await withTaskCancellationHandler { await writer.finished() } onCancel: { task.cancel(); writer.cancel() }
            if let status = result.status, !(200..<300).contains(status) { try? FileManager.default.removeItem(at: file); throw CaptureError(errorDescription: "The provider answered \(status). It may allow only one stream at a time.") }
            if result.bytes == 0 { try? FileManager.default.removeItem(at: file); throw CaptureError(errorDescription: result.error ?? "Nothing was received.") }
            return .success(())
        } catch { return .failure(error) }
    }
}

/// Writes what arrives to a file, and stops at a time.
private final class StreamWriter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Result { var bytes: Int; var status: Int?; var error: String? }
    private let handle: FileHandle
    private let until: Date
    private let lock = NSLock()
    private var result = Result(bytes: 0, status: nil, error: nil)
    private var waiter: CheckedContinuation<Result, Never>?
    private var done = false

    init(handle: FileHandle, until: Date) { self.handle = handle; self.until = until }

    func finished() async -> Result {
        await withCheckedContinuation { k in
            lock.lock()
            if done { let r = result; lock.unlock(); k.resume(returning: r) } else { waiter = k; lock.unlock() }
        }
    }

    func cancel() { finish() }

    private func finish() {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true; let w = waiter; waiter = nil; let r = result; lock.unlock()
        w?.resume(returning: r)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); result.status = (response as? HTTPURLResponse)?.statusCode; lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do { try handle.write(contentsOf: data); lock.lock(); result.bytes += data.count; lock.unlock() } catch { lock.lock(); result.error = "The disk could not be written to."; lock.unlock(); dataTask.cancel(); finish(); return }
        if Date() >= until { dataTask.cancel(); finish() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, (error as NSError).code != NSURLErrorCancelled { lock.lock(); result.error = error.localizedDescription; lock.unlock() }
        finish()
    }
}
#endif
