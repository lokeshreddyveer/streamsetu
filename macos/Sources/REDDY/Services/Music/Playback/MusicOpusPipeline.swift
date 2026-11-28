import Foundation

/// Reads an Opus file through ranged reads and turns it into packets, with seeking. It owns one demuxer (WebM or Ogg, chosen from the first
/// bytes) and the read-ahead; it does no decoding and no audio output, so it is testable with an in-memory source.
///
/// Not thread-safe: one task drives it at a time.
final class MusicOpusPipeline: @unchecked Sendable {
    static let firstChunk = 32 * 1024
    static let chunk = 128 * 1024
    /// A file whose header is not found in this many bytes is not read further.
    static let headerLimit = 4 * 1_048_576

    let source: MusicOpusByteSource
    private(set) var container: MusicMediaContainer = .other
    private(set) var info: MusicOpusTrackInfo?
    private(set) var total: Int64?
    private var webm: MusicWebMDemuxer?
    private var ogg: MusicOggOpusDemuxer?
    private var carry: [MusicOpusPacket] = []
    private var nextOffset: Int64 = 0
    private var prefetch: Task<(data: [UInt8], total: Int64?), Error>?
    private var reads = 0
    private(set) var endReached = false
    /// Where the audio starts in the file (the first cluster, or for Ogg the first page after the headers).
    private var audioStart: Int64 = 0

    init(source: MusicOpusByteSource) { self.source = source }

    func cancel() { prefetch?.cancel(); prefetch = nil }

    // MARK: opening

    /// Reads until the stream header is known. Throws `unsupported` for another container or codec.
    func open() async throws -> MusicOpusTrackInfo {
        let first = try await readChunk()
        guard !first.isEmpty else { throw MusicOpusError.malformed("empty file") }
        container = MusicMediaContainer.sniff(first)
        switch container {
        case .webm: webm = MusicWebMDemuxer()
        case .ogg: ogg = MusicOggOpusDemuxer()
        default: throw MusicOpusError.unsupported("not WebM or Ogg")
        }
        var pending: [UInt8]? = first
        while info == nil {
            let bytes: [UInt8]
            if let p = pending { bytes = p; pending = nil } else {
                guard nextOffset < Self.headerLimit else { throw MusicOpusError.malformed("no audio header found") }
                bytes = try await readChunk()
                guard !bytes.isEmpty else { throw MusicOpusError.malformed("the file ends before the audio header") }
            }
            try ingest(bytes)
            if info == nil, let w = webm, w.reachedClusters { throw MusicOpusError.unsupported(w.unsupportedReason ?? "no Opus track") }
        }
        guard let i = info else { throw MusicOpusError.malformed("no audio header found") }
        if container == .ogg, i.duration == nil, let t = total, t > 0 {
            let tailStart = max(0, t - 65_536)
            if let r = try? await source.read(offset: tailStart, length: Int(t - tailStart)), let g = MusicOggOpusDemuxer.lastGranule(in: r.data) {
                info?.duration = MusicOggOpusDemuxer.duration(lastGranule: g, preSkip: i.head.preSkip)
            }
        }
        audioStart = webm?.firstClusterOffset ?? 0
        return info ?? i
    }

    // MARK: reading

    /// The next packets in file order, or nil at the end of the file.
    func nextPackets() async throws -> [MusicOpusPacket]? {
        while carry.isEmpty {
            if endReached { return nil }
            let bytes = try await readChunk()
            if bytes.isEmpty { endReached = true; return nil }
            try ingest(bytes)
        }
        let out = carry
        carry = []
        return out
    }

    private func ingest(_ bytes: [UInt8]) throws {
        let events: [MusicOpusEvent]
        if webm != nil { events = try webm?.feed(bytes) ?? [] } else { events = try ogg?.feed(bytes) ?? [] }
        for e in events {
            switch e {
            case .track(let t): if info == nil { info = t }
            case .duration(let d): if info != nil { info?.duration = d }
            case .cues: break
            case .packet(let p): carry.append(p)
            }
        }
    }

    private func readChunk() async throws -> [UInt8] {
        let size = reads == 0 ? Self.firstChunk : Self.chunk
        reads += 1
        let r: (data: [UInt8], total: Int64?)
        if let p = prefetch { prefetch = nil; r = try await p.value } else { r = try await source.read(offset: nextOffset, length: size) }
        if let t = r.total { total = t }
        nextOffset += Int64(r.data.count)
        if !r.data.isEmpty, total.map({ nextOffset < $0 }) ?? true {
            let at = nextOffset
            let src = source
            prefetch = Task { try await src.read(offset: at, length: Self.chunk) }
        }
        return r.data
    }

    // MARK: seeking

    /// Repositions so the next packets come from at or just before `time`. The caller drops what is earlier than the target.
    func seek(to time: Double) async throws {
        cancel()
        carry = []
        endReached = false
        let target = max(0, time)
        if webm != nil { try await seekWebM(target) } else { try await seekOgg(target) }
    }

    private func seekWebM(_ target: Double) async throws {
        guard var w = webm else { return }
        var cues = w.cues
        if cues.isEmpty, let segStart = w.segmentDataStart, let pos = w.cuesPosition {
            var probe = w
            probe.restart(atOffset: segStart + pos, clusterAligned: true)
            if let r = try? await source.read(offset: segStart + pos, length: 512 * 1024) {
                for case .cues(let c) in (try? probe.feed(r.data)) ?? [] { cues = c }
            }
        }
        if let cue = MusicWebMDemuxer.cue(for: target, in: cues), let segStart = w.segmentDataStart {
            let at = segStart + cue.position
            w.restart(atOffset: at, clusterAligned: true)
            nextOffset = at
        } else {
            // No cues: estimate from the byte rate and scan forward for a cluster.
            var at = audioStart
            if let t = total, let d = info?.duration, d > 0, t > audioStart { at = audioStart + Int64(Double(t - audioStart) * min(1, target / d)) }
            w.restart(atOffset: at, clusterAligned: audioStart == at)
            nextOffset = at
        }
        webm = w
        reads = 1
    }

    private func seekOgg(_ target: Double) async throws {
        guard var o = ogg, let preSkip = info?.head.preSkip else { return }
        var lo: (off: Int64, t: Double) = (0, 0)
        var hi: (off: Int64, t: Double)?
        if let t = total, let d = info?.duration { hi = (t, d) }
        if target > 0 {
            for _ in 0..<10 {
                guard let h = hi, h.t > lo.t else { break }
                let ratio = min(max((target - lo.t) / (h.t - lo.t), 0), 1)
                let guess = lo.off + Int64(Double(h.off - lo.off) * ratio)
                guard let r = try? await source.read(offset: guess, length: 64 * 1024), let g = MusicOggOpusDemuxer.firstGranule(in: r.data) else { break }
                let t = Double(max(0, g.granule - Int64(preSkip))) / 48_000
                if t <= target { lo = (guess + Int64(g.at), t); if target - t < 0.4 { break } } else { hi = (guess, t) }
                if let now = hi, now.off - lo.off < 4096 { break }
            }
        }
        o.restart(atOffset: lo.off)
        ogg = o
        nextOffset = lo.off
        reads = 1
    }
}
