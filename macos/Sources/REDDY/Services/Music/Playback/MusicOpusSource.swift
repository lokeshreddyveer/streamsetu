import Foundation

/// Where the bytes of an Opus file come from: ranged reads, so a seek never downloads what it skips.
protocol MusicOpusByteSource: Sendable {
    /// Up to `length` bytes starting at `offset`, plus the whole file's size when the source knows it. An empty result means the end.
    func read(offset: Int64, length: Int) async throws -> (data: [UInt8], total: Int64?)
}

/// A file on disk.
struct MusicOpusFileSource: MusicOpusByteSource {
    let url: URL

    func read(offset: Int64, length: Int) async throws -> (data: [UInt8], total: Int64?) {
        let url = self.url
        return try await Task.detached(priority: .userInitiated) {
            let h = try FileHandle(forReadingFrom: url)
            defer { try? h.close() }
            let total = Int64(try h.seekToEnd())
            guard offset < total else { return ([], total) }
            try h.seek(toOffset: UInt64(offset))
            let d = try h.read(upToCount: length) ?? Data()
            return ([UInt8](d), total)
        }.value
    }
}

/// Bytes in memory (tests, small cached files).
struct MusicOpusMemorySource: MusicOpusByteSource {
    let bytes: [UInt8]

    func read(offset: Int64, length: Int) async throws -> (data: [UInt8], total: Int64?) {
        let total = Int64(bytes.count)
        guard offset >= 0, offset < total else { return ([], total) }
        let end = min(bytes.count, Int(offset) + length)
        return (Array(bytes[Int(offset)..<end]), total)
    }
}

/// A remote file read with bounded Range requests through the app's transfer client (the person's proxy and the address checks apply).
/// Bounded ranges also avoid the throttling some hosts apply to open-ended ones.
struct MusicOpusHTTPSource: MusicOpusByteSource {
    let url: URL
    var headers: [String: String] = [:]

    func read(offset: Int64, length: Int) async throws -> (data: [UInt8], total: Int64?) {
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")
        let (data, resp) = try await MusicTransfer.data(for: req, maxBytes: length + 4096)
        switch resp.statusCode {
        case 206:
            let total = (resp.value(forHTTPHeaderField: "Content-Range")).flatMap { MusicProxyHTTP.parseContentRange($0)?.total }
            return ([UInt8](data), total)
        case 200:
            // The server ignored the range and sent the file from its start.
            guard offset == 0 else { throw MusicOpusError.network("the server does not support seeking") }
            return ([UInt8](data.prefix(length)), Int64(data.count))
        case 416:
            return ([], resp.value(forHTTPHeaderField: "Content-Range").flatMap { MusicProxyHTTP.parseContentRange($0)?.total })
        default:
            throw MusicOpusError.network("HTTP \(resp.statusCode)")
        }
    }
}

// MARK: routing

/// Decides when a stream goes to the Opus backend instead of the system player.
enum MusicOpusRouting {
    /// The Opus backend can run on this system.
    static var isAvailable: Bool { MusicOpusDecoder.isAvailable }

    /// True when a stream's own description says WebM or Ogg, which the system player cannot open.
    static func declaresOpusContainer(_ s: MusicStream) -> Bool {
        let c = MusicMediaContainer.declared(container: s.container, codec: s.codec, url: URL(string: s.url))
        return c == .webm || c == .ogg
    }

    /// True when the description is silent about the container, so the first bytes have to be read.
    static func needsSniff(_ s: MusicStream) -> Bool {
        MusicMediaContainer.declared(container: s.container, codec: s.codec, url: URL(string: s.url)) == nil
    }

    /// The container of a source, read from its first bytes.
    static func sniff(_ source: MusicOpusByteSource) async -> MusicMediaContainer {
        guard let r = try? await source.read(offset: 0, length: 16) else { return .other }
        return MusicMediaContainer.sniff(r.data)
    }

    /// A byte source for a stream: a file for file addresses, ranged HTTP for web addresses.
    static func source(for s: MusicStream) -> MusicOpusByteSource? {
        guard let u = URL(string: s.url) else { return nil }
        if u.isFileURL { return MusicOpusFileSource(url: u) }
        guard MusicTransfer.isAllowed(u) else { return nil }
        return MusicOpusHTTPSource(url: u, headers: s.headers)
    }
}
