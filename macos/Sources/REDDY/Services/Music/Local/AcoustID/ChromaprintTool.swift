import Foundation

/// Makes a fingerprint with Chromaprint's own `fpcalc` tool: the first two minutes of the file, as JSON. Music does not link Chromaprint (it is LGPL as a whole);
/// it runs the tool the person chose, or the one packaged with the app (Scripts/fetch-fpcalc.sh), as a separate process. Only macOS can run a helper process, so
/// recognising by sound is a Mac feature. Playback never waits for it: it runs only when the person asks to identify a song, one file at a time, and can be cancelled.
enum ChromaprintTool {
    static let seconds = 120
    static let timeout: TimeInterval = 60
    static let pathKey = "music.local.fpcalcPath"

    /// Where `fpcalc` may be: one the person chose, one packaged with the app, then the usual Homebrew places.
    static func candidates(defaults: UserDefaults = .standard, bundle: Bundle = .main) -> [String] {
        var out: [String] = []
        if let p = defaults.string(forKey: pathKey), !p.isEmpty { out.append(p) }
        if let p = bundle.url(forAuxiliaryExecutable: "fpcalc")?.path { out.append(p) }
        out += ["/opt/homebrew/bin/fpcalc", "/usr/local/bin/fpcalc"]
        return out
    }

    static func locate(fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }, defaults: UserDefaults = .standard) -> String? {
        candidates(defaults: defaults).first(where: fileExists)
    }

    enum Failure: Error, Equatable, Sendable { case notInstalled, unsupported, unreadable, timedOut }

    #if os(macOS)
    /// One run of the tool: the process, its output pipe, and a lock so the answer is delivered exactly once, whichever of "finished", "timed out" or "cancelled" comes first.
    private final class Run: @unchecked Sendable {
        let process = Process()
        let out = Pipe(), err = Pipe()
        private let lock = NSLock()
        private var continuation: CheckedContinuation<(duration: Int, fingerprint: String), Error>?

        func begin(_ c: CheckedContinuation<(duration: Int, fingerprint: String), Error>) { lock.lock(); continuation = c; lock.unlock() }

        func finish(_ r: Result<(duration: Int, fingerprint: String), Error>) {
            lock.lock(); let c = continuation; continuation = nil; lock.unlock()
            c?.resume(with: r)
        }

        func stop() { if process.isRunning { process.terminate() } }
    }

    /// Fingerprints `file`. Cancelling the task stops the process.
    static func fingerprint(_ file: URL, tool: String? = nil) async throws -> (duration: Int, fingerprint: String) {
        guard let path = tool ?? locate() else { throw Failure.notInstalled }
        let run = Run()
        run.process.executableURL = URL(fileURLWithPath: path)
        run.process.arguments = ["-json", "-length", String(seconds), "--", file.path]
        run.process.standardOutput = run.out
        run.process.standardError = FileHandle.nullDevice
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<(duration: Int, fingerprint: String), Error>) in
                run.begin(c)
                if Task.isCancelled { run.finish(.failure(CancellationError())); return }
                run.process.terminationHandler = { p in
                    let data = run.out.fileHandleForReading.readDataToEndOfFile()
                    if p.terminationStatus == 0, let r = ChromaprintOutput.parse(data) { run.finish(.success(r)) } else { run.finish(.failure(Failure.unreadable)) }
                }
                do { try run.process.run() } catch { run.finish(.failure(Failure.notInstalled)); return }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if run.process.isRunning { run.stop(); run.finish(.failure(Failure.timedOut)) } }
            }
        } onCancel: { run.stop(); run.finish(.failure(CancellationError())) }
    }
    #else
    static func fingerprint(_ file: URL, tool: String? = nil) async throws -> (duration: Int, fingerprint: String) { throw Failure.unsupported }
    #endif
}
