import Foundation

struct DownloadResult: Sendable {
    let fileURL: URL?
    let status: Int
    let etag: String?
    let lastModified: String?
    let bytes: Int64
    var notModified: Bool { status == 304 }
}

/// Downloads to a temporary file (never into memory), enforces size limits, supports cancellation.
final class HTTPClient: @unchecked Sendable {
    let config: NetworkConfiguration
    let builder: RequestBuilder
    private let lock = NSLock()
    private var _session: URLSession
    private var session: URLSession { lock.withLock { _session } }

    init(config: NetworkConfiguration = .default) {
        self.config = config
        self.builder = RequestBuilder(config: config)
        _session = Self.makeSession(config, proxy: nil)
    }

    private static func makeSession(_ config: NetworkConfiguration, proxy: ProxyConfig?) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = config.requestTimeout
        c.waitsForConnectivity = false
        c.httpMaximumConnectionsPerHost = 4
        if let dict = proxy?.connectionDictionary { c.connectionProxyDictionary = dict }
        return URLSession(configuration: c)
    }

    /// The proxy the live session sends requests through, for checking that a Settings change really reached the network layer.
    var activeProxyDictionary: [AnyHashable: Any]? { session.configuration.connectionProxyDictionary }

    /// Routes later requests through a proxy (or stops doing so). Requests already running finish as they were.
    func setProxy(_ proxy: ProxyConfig?) {
        let fresh = Self.makeSession(config, proxy: proxy)
        lock.withLock { _session.finishTasksAndInvalidate(); _session = fresh }
    }

    static let tempDirectory: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("REDDY-downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    func download(_ request: URLRequest, maxBytes: Int64,
                  progress: (@Sendable (Int64, Int64?) -> Void)? = nil) async throws -> DownloadResult {
        let delegate = DownloadDelegate(maxBytes: maxBytes, progress: progress)
        let task = session.downloadTask(with: request)
        task.delegate = delegate
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<DownloadResult, Error>) in
                delegate.continuation = cont
                task.resume()
            }
        } onCancel: { task.cancel() }
    }

    /// Small responses (JSON). Still downloaded to disk first, then mapped.
    func data(_ request: URLRequest, maxBytes: Int64) async throws -> Data {
        let r = try await RetryPolicy.standard.run { [self] in try await download(request, maxBytes: maxBytes) }
        guard let url = r.fileURL else { throw NetworkError.unreadable }
        defer { try? FileManager.default.removeItem(at: url) }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    func downloadWithRetry(_ request: URLRequest, maxBytes: Int64,
                           progress: (@Sendable (Int64, Int64?) -> Void)? = nil) async throws -> DownloadResult {
        try await RetryPolicy.standard.run { [self] in try await download(request, maxBytes: maxBytes, progress: progress) }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    var continuation: CheckedContinuation<DownloadResult, Error>?
    private let maxBytes: Int64
    private let progress: (@Sendable (Int64, Int64?) -> Void)?
    private var moved: URL?
    private var failure: Error?
    private let lock = NSLock()

    /// A redirect to another host, port or scheme repeats the request without the logins we sent (see RedirectPolicy).
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(RedirectPolicy.sanitized(request, after: task.originalRequest ?? request))
    }

    init(maxBytes: Int64, progress: (@Sendable (Int64, Int64?) -> Void)?) {
        self.maxBytes = maxBytes
        self.progress = progress
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64) {
        if written > maxBytes {
            lock.lock(); failure = NetworkError.tooLarge(limit: maxBytes); lock.unlock()
            downloadTask.cancel()
            return
        }
        progress?(written, expected > 0 ? expected : nil)
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let dest = HTTPClient.tempDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            lock.lock(); moved = dest; lock.unlock()
        } catch {
            lock.lock(); failure = error; lock.unlock()
        }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let cont = continuation; continuation = nil
        let file = moved, fail = failure
        lock.unlock()
        guard let cont else { return }

        func cleanup() { if let file { try? FileManager.default.removeItem(at: file) } }
        if let fail { cleanup(); return cont.resume(throwing: fail) }
        if let error { cleanup(); return cont.resume(throwing: NetworkError.from(error)) }
        guard let http = task.response as? HTTPURLResponse else { cleanup(); return cont.resume(throwing: NetworkError.unreadable) }
        if http.statusCode == 304 {
            cleanup()
            return cont.resume(returning: DownloadResult(fileURL: nil, status: 304, etag: http.value(forHTTPHeaderField: "ETag"),
                                                         lastModified: http.value(forHTTPHeaderField: "Last-Modified"), bytes: 0))
        }
        guard (200..<300).contains(http.statusCode) else {
            cleanup()
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            return cont.resume(throwing: NetworkError.http(status: http.statusCode, retryAfter: retry))
        }
        let size = (file.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int64 }) ?? 0
        cont.resume(returning: DownloadResult(fileURL: file, status: http.statusCode, etag: http.value(forHTTPHeaderField: "ETag"),
                                              lastModified: http.value(forHTTPHeaderField: "Last-Modified"), bytes: size))
    }
}
