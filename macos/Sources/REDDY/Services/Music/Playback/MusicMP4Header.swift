import Foundation

/// A fragmented MP4 audio file (what YouTube serves as itag 140) states its length in the track header (`mdhd`); AVFoundation reads that
/// length wrongly for these files and reports twice the song (a 4:22 song as 8:42, with silence for the extra half). The same file with the
/// header length set to zero is measured from its fragments and comes out right. This rewrites those header lengths in the bytes the player
/// asks for first. The size of the file and every offset in it stay as they are, so ranges keep working.
enum MusicMP4Header {
    /// Zeroes the duration of every `mdhd` inside the `moov` box at the start of a fragmented file.
    /// Only a piece that starts at file offset 0 and holds the whole `moov` is touched. Returns true when something changed.
    @discardableResult
    static func neutraliseDurations(in data: inout Data, fileOffset: Int64) -> Bool {
        guard fileOffset == 0, data.count >= 16 else { return false }
        let base = data.startIndex
        func u32(_ o: Int) -> Int { data[base + o..<base + o + 4].reduce(0) { $0 << 8 | Int($1) } }
        func type(_ o: Int) -> String { String(decoding: data[base + o + 4..<base + o + 8], as: UTF8.self) }
        // The top level: ftyp, then moov (found before any media data, which would mean a plain file with no moov up front).
        var o = 0
        var moov: Range<Int>?
        while o + 8 <= data.count {
            let size = u32(o)
            guard size >= 8 else { return false }
            let t = type(o)
            if t == "moov" { if o + size <= data.count { moov = (o + 8)..<(o + size) }; break }
            if t == "mdat" || t == "moof" { return false }
            o += size
        }
        guard let moov else { return false }
        // Only a fragmented file (it carries an mvex box) is touched: a plain file's header length is the real one.
        guard contains("mvex", in: moov, size: u32, type: type) else { return false }
        var changed = false
        func zero(_ at: Int, _ len: Int) {
            for i in 0..<len where data[base + at + i] != 0 { data[base + at + i] = 0; changed = true }
        }
        func walk(_ range: Range<Int>) {
            var p = range.lowerBound
            while p + 8 <= range.upperBound {
                let size = u32(p)
                guard size >= 8, p + size <= range.upperBound else { return }
                let t = type(p)
                let body = p + 8
                switch t {
                case "trak", "mdia": walk(body..<(p + size))
                case "mdhd":
                    // flags(4), creation, modification, timescale (4 each in version 0, 8+8+4 in version 1), then the duration.
                    let version = Int(data[base + body])
                    if version == 1 { zero(body + 24, 8) } else { zero(body + 16, 4) }
                default: break
                }
                p += size
            }
        }
        walk(moov)
        return changed
    }

    private static func contains(_ name: String, in range: Range<Int>, size: (Int) -> Int, type: (Int) -> String) -> Bool {
        var p = range.lowerBound
        while p + 8 <= range.upperBound {
            let s = size(p)
            guard s >= 8 else { return false }
            if type(p) == name { return true }
            p += s
        }
        return false
    }
}
