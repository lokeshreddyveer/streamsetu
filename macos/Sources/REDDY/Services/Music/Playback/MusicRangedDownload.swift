import Foundation

/// Which container a file really is, read from its first bytes. A stream's declared type is sometimes wrong, and the extension decides how the
/// file opens later.
enum MusicContainerSniff {
    static func fileExtension(firstBytes d: Data, mime: String? = nil) -> String? {
        let b = [UInt8](d.prefix(512))
        func at(_ i: Int, _ s: String) -> Bool { let u = Array(s.utf8); return b.count >= i + u.count && Array(b[i..<(i + u.count)]) == u }
        if at(0, "fLaC") { return "flac" }
        if at(0, "RIFF"), at(8, "WAVE") { return "wav" }
        if at(4, "ftyp") { return at(8, "M4A") || at(8, "mp42") || at(8, "isom") || at(8, "dash") || at(8, "iso") ? "m4a" : "mp4" }
        if at(0, "OggS") { return "ogg" }
        if b.count >= 4, b[0] == 0x1A, b[1] == 0x45, b[2] == 0xDF, b[3] == 0xA3 { return "webm" }
        if at(0, "ID3") { return "mp3" }
        if b.count >= 2, b[0] == 0xFF, (b[1] & 0xF6) == 0xF0 { return "aac" }
        if b.count >= 2, b[0] == 0xFF, (b[1] & 0xE0) == 0xE0 { return "mp3" }
        if at(0, "#EXTM3U") || at(0, "<MPD") { return nil }
        if let m = mime?.lowercased() {
            if m.contains("mpeg") { return "mp3" }
            if m.contains("mp4") || m.contains("m4a") || m.contains("aac") { return "m4a" }
            if m.contains("flac") { return "flac" }
            if m.contains("ogg") { return "ogg" }
            if m.contains("webm") { return "webm" }
        }
        return nil
    }
}

/// Downloads a file in bounded ranges, so hosts that serve only small windows still deliver the whole file. A refused window (403, 404 or 410)
/// asks for a fresh address once; the new address must report the same total length or the download stops.
enum MusicRangedDownloader {
    struct Answer: Sendable { var status: Int; var data: Data; var total: Int64? }
    struct Source: Sendable { var url: URL; var headers: [String: String]; var total: Int64? }
    struct Outcome: Sendable { var bytes: Int64; var firstBytes: Data }

    enum Failure: Error, Equatable, Sendable, LocalizedError {
        case refused(Int), changed, stalled, noLength
        var errorDescription: String? {
            switch self {
            case .refused(let c): return "The server refused the file (\(c))."
            case .changed: return "The stream changed while it was downloading."
            case .stalled: return "The download stalled."
            case .noLength: return "The server did not say how large the file is."
            }
        }
    }

    typealias Fetch = @Sendable (_ url: URL, _ headers: [String: String], _ range: ClosedRange<Int64>) async throws -> Answer
    typealias Reresolve = @Sendable () async -> Source?
    static let refusals: Set<Int> = [403, 404, 410]

    static func window(for url: URL) -> Int64 { min(2 * 1_048_576, MusicProxyPolicy.window(for: url)) }

    static func run(source: Source, destination: URL, fetch: Fetch, reresolve: Reresolve, progress: @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws -> Outcome {
        var src = source
        var total = source.total
        if total == nil {
            let a = try await fetch(src.url, src.headers, 0...0)
            guard (a.status == 206 || a.status == 200), let t = a.total, t > 0 else { throw refusals.contains(a.status) ? Failure.refused(a.status) : Failure.noLength }
            total = t
        }
        guard let length = total, length > 0 else { throw Failure.noLength }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var offset: Int64 = 0
        var first = Data()
        var reresolved = false
        var retriedWindow = false
        while offset < length {
            if Task.isCancelled { throw MusicError.cancelled }
            let end = min(length - 1, offset + window(for: src.url) - 1)
            let want = end - offset + 1
            let a: Answer
            do { a = try await fetch(src.url, src.headers, offset...end) } catch {
                if error is CancellationError || (error as? MusicError) == .cancelled { throw MusicError.cancelled }
                if retriedWindow { throw Failure.stalled }
                retriedWindow = true
                continue
            }
            if refusals.contains(a.status) {
                guard !reresolved else { throw Failure.refused(a.status) }
                reresolved = true
                guard let fresh = await reresolve() else { throw Failure.refused(a.status) }
                guard fresh.total == length else { throw Failure.changed }
                src = fresh
                continue
            }
            guard a.status == 206, Int64(a.data.count) == want else {
                if retriedWindow { throw Failure.stalled }
                retriedWindow = true
                continue
            }
            retriedWindow = false
            if first.isEmpty { first = a.data.prefix(512) }
            var chunk = a.data
            if offset == 0 { MusicMP4Header.neutraliseDurations(in: &chunk, fileOffset: 0) }
            try handle.write(contentsOf: chunk)
            offset += want
            progress(offset, length)
        }
        return Outcome(bytes: offset, firstBytes: first)
    }

    /// The real reader: one ranged GET through the app's transfer client.
    static let live: Fetch = { url, headers, range in
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        req.timeoutInterval = 20
        let (data, http) = try await MusicTransfer.data(for: req, maxBytes: 3_000_000)
        let total = http.value(forHTTPHeaderField: "Content-Range").flatMap(MusicProxyHTTP.parseContentRange)?.total
        return Answer(status: http.statusCode, data: data, total: total)
    }
}
