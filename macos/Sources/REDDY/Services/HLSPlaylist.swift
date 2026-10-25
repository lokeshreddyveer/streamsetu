import Foundation

/// Just enough of an HLS playlist (.m3u8) to record a channel: which streams a master playlist offers and which segments a media playlist lists.
struct HLSPlaylist: Equatable {
    struct Variant: Equatable { let bandwidth: Int; let url: URL }
    struct Segment: Equatable { let sequence: Int; let url: URL; let duration: Double }

    var isMaster = false
    var variants: [Variant] = []
    var segments: [Segment] = []
    var targetDuration: Double = 6
    var ended = false
    /// Segments are encrypted, so writing them to a file would make an unplayable recording.
    var encrypted = false
    /// Segments are fragmented MP4 pieces, which are not plain transport stream and cannot simply be joined.
    var fragmentedMP4 = false
    /// Segments are parts of one file named by byte range; fetching each address whole would repeat or mix up the pieces.
    var byteRanged = false

    static func looksLikePlaylist(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") }

    static func parse(_ text: String, base: URL) -> HLSPlaylist {
        var p = HLSPlaylist()
        var sequence = 0, nextDuration = 0.0, pendingBandwidth: Int?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                if line.hasPrefix("#EXT-X-STREAM-INF:") {
                    p.isMaster = true
                    pendingBandwidth = Int(attribute("BANDWIDTH", in: line) ?? "") ?? 0
                } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") { sequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0 }
                else if line.hasPrefix("#EXT-X-TARGETDURATION:") { p.targetDuration = Double(line.dropFirst("#EXT-X-TARGETDURATION:".count)) ?? 6 }
                else if line.hasPrefix("#EXTINF:") { nextDuration = Double(line.dropFirst("#EXTINF:".count).split(separator: ",").first ?? "") ?? 0 }
                else if line.hasPrefix("#EXT-X-ENDLIST") { p.ended = true }
                else if line.hasPrefix("#EXT-X-KEY:"), let method = attribute("METHOD", in: line), method != "NONE" { p.encrypted = true }
                else if line.hasPrefix("#EXT-X-MAP:") { p.fragmentedMP4 = true }
                else if line.hasPrefix("#EXT-X-BYTERANGE:") { p.byteRanged = true }
                continue
            }
            guard let url = URL(string: line, relativeTo: base)?.absoluteURL else { continue }
            if let bw = pendingBandwidth { p.variants.append(Variant(bandwidth: bw, url: url)); pendingBandwidth = nil }
            else { p.segments.append(Segment(sequence: sequence, url: url, duration: nextDuration)); sequence += 1; nextDuration = 0 }
        }
        return p
    }

    /// The stream to record from a master playlist: the highest bandwidth the provider lists.
    var bestVariant: Variant? { variants.max { $0.bandwidth < $1.bandwidth } }

    private static func attribute(_ name: String, in line: String) -> String? {
        guard let r = line.range(of: name + "=") else { return nil }
        let rest = line[r.upperBound...]
        if rest.hasPrefix("\"") { return rest.dropFirst().prefix { $0 != "\"" }.description }
        return rest.prefix { $0 != "," }.description
    }
}
