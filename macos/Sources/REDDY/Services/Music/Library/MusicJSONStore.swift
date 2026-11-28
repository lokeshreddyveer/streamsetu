import Foundation

// A small atomic JSON file store used by the music library. One store owns one file.
// The file holds an envelope with a schemaVersion so later versions can migrate instead of guessing.

enum MusicJSONCoding {
    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

struct MusicJSONEnvelope<Value: Codable & Sendable>: Codable, Sendable {
    var schemaVersion: Int
    var value: Value
}

/// Serial background writer so encoding and disk work never block the main thread and writes never reorder.
private final class MusicJSONWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "StreamSetu.Music.JSONWriter", qos: .utility)

    func write<Value: Codable & Sendable>(_ value: Value, version: Int, to url: URL, wait: Bool) {
        let work: @Sendable () -> Void = {
            guard let data = try? MusicJSONCoding.makeEncoder().encode(MusicJSONEnvelope(schemaVersion: version, value: value)) else { return }
            try? data.write(to: url, options: .atomic)
        }
        if wait { queue.sync(execute: work) } else { queue.async(execute: work) }
    }

    func remove(_ url: URL) {
        queue.sync { try? FileManager.default.removeItem(at: url) }
    }

    func drain() { queue.sync {} }
}

@MainActor
final class MusicJSONStore<Value: Codable & Sendable> {
    let url: URL
    let schemaVersion: Int
    private let debounce: Duration
    private let writer = MusicJSONWriter()
    private var pending: Value?
    private var timer: Task<Void, Never>?

    init(url: URL, schemaVersion: Int = 1, debounce: Duration = .seconds(1)) {
        self.url = url
        self.schemaVersion = schemaVersion
        self.debounce = debounce
    }

    /// Reads the file. A missing file gives nil. An unreadable file is moved aside to `*.bad` (so nothing is lost) and gives nil.
    func load() -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let env = try? MusicJSONCoding.makeDecoder().decode(MusicJSONEnvelope<Value>.self, from: data) {
            return env.value
        }
        quarantine()
        return nil
    }

    /// Queues a save. Calls within the debounce window collapse into one write of the newest value.
    func save(_ value: Value) {
        pending = value
        guard timer == nil else { return }
        let delay = debounce
        timer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            self?.timerFired()
        }
    }

    private func timerFired() {
        timer = nil
        if let value = pending {
            pending = nil
            writer.write(value, version: schemaVersion, to: url, wait: false)
        }
    }

    /// Writes any queued value now and waits until everything is on disk.
    func flush() {
        timer?.cancel()
        timer = nil
        if let value = pending {
            pending = nil
            writer.write(value, version: schemaVersion, to: url, wait: true)
        } else {
            writer.drain()
        }
    }

    /// Drops anything queued and deletes the file and any quarantined copy.
    func delete() {
        timer?.cancel()
        timer = nil
        pending = nil
        writer.remove(url)
        writer.remove(badURL)
    }

    private var badURL: URL { url.appendingPathExtension("bad") }

    private func quarantine() {
        let fm = FileManager.default
        try? fm.removeItem(at: badURL)
        try? fm.moveItem(at: url, to: badURL)
    }
}
