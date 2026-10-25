import Foundation

/// A short, local log of what playback did: when a stream started, which player took it, how it ended, and why it failed. Kept in every
/// build (it is how a problem on a phone can be understood afterwards), on this device only, trimmed automatically, and never holding a
/// login or a full stream address (every line goes through the credential redactor first). It leaves the device only if the person
/// chooses Send Feedback and includes diagnostics.
final class PlaybackLog: @unchecked Sendable {
    /// A test run writes to its own folder, never to the person's real log.
    static let shared: PlaybackLog = {
        if DiagnosticsUploader.underTests {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("streamsetu-tests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return PlaybackLog(url: dir.appendingPathComponent("playback.log"))
        }
        return PlaybackLog(url: StorageService.ensure(StorageService.applicationSupport.appendingPathComponent("Logs", isDirectory: true)).appendingPathComponent("playback.log"))
    }()

    let url: URL
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "app.streamsetu.playbacklog", qos: .utility)
    private var lastLine = ""
    private var repeats = 0
    private var started = false

    init(url: URL, maxBytes: Int = 1_000_000) { self.url = url; self.maxBytes = maxBytes }

    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss.SSS"; return f
    }()

    func append(_ line: String, now: Date = Date()) {
        queue.async { [self] in
            if !started { started = true; write("--- launch \(Self.environment) ---", at: now) }
            if line == lastLine { repeats += 1; return }          // the same line over and over (a decoder warning) is counted, not stored
            if repeats > 0 { write("   (the line above repeated \(repeats) more times)", at: now) }
            lastLine = line; repeats = 0
            write(line, at: now)
        }
    }

    /// The newest lines, oldest first. Waits for pending writes, so it is safe to call right after `append`.
    func tail(lines: Int = 200) -> [String] {
        queue.sync {
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return [] }
            return Array(text.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).map(String.init))
        }
    }

    func clear() { queue.sync { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: rotated); lastLine = ""; repeats = 0; started = false } }

    private var rotated: URL { url.deletingPathExtension().appendingPathExtension("1.log") }

    private func write(_ line: String, at date: Date) {
        let text = Self.stamp.string(from: date) + "  " + line + "\n"
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int), size > maxBytes {
            try? fm.removeItem(at: rotated)
            try? fm.moveItem(at: url, to: rotated)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data(text.utf8))
    }

    private static var environment: String {
        let info = Bundle.main.infoDictionary
        let v = "\(info?["CFBundleShortVersionString"] as? String ?? "dev") (\(info?["CFBundleVersion"] as? String ?? "0"))"
        return "\(v) \(DiagnosticsService.platformName) \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }
}
