import Foundation
import AVFoundation

// A picture of a song's loudness over time (for tapping to seek and for finding silence at the ends) and CUE sheet chapters (an album in one file, a medley, the
// movements of a work). Both are read from the person's own local files only; nothing is uploaded and nothing is written to the file.

enum MusicWaveform {
    static let buckets = 240

    /// Loudness per slice, 0...1 (the loudest slice is 1). Decoded to mono at 8 kHz, which is plenty for a picture and cheap. Nil when the file cannot be read.
    static func peaks(of file: URL, buckets n: Int = buckets, isCancelled: @Sendable () -> Bool = { false }) async -> [Float]? {
        let asset = AVURLAsset(url: file)
        guard let secs = try? await asset.load(.duration).seconds, secs.isFinite, secs > 0,
              let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let rate = 8000.0
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                                       AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1]
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { return nil }
        reader.add(out)
        guard reader.startReading() else { return nil }
        var peaks = [Float](repeating: 0, count: n)
        let perBucket = max(1.0, secs * rate / Double(n))
        var frame = 0.0
        while let sample = out.copyNextSampleBuffer() {
            if isCancelled() { reader.cancelReading(); return nil }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let len = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: len / 4)
            let ok = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
            guard ok == kCMBlockBufferNoErr else { return nil }
            for v in data {
                let b = min(n - 1, Int(frame / perBucket))
                let a = abs(v)
                if a > peaks[b] { peaks[b] = a }
                frame += 1
            }
            await Task.yield()
        }
        if reader.status == .failed { return nil }
        let top = peaks.max() ?? 0
        return top > 0 ? peaks.map { $0 / top } : peaks
    }

    /// How long the quiet lead-in and tail are, in seconds: the run of slices below `threshold` (a fraction of the loudest) at each end. Never more than a third of the song each.
    static func silence(peaks: [Float], duration: Double, threshold: Float = 0.02) -> (lead: Double, trail: Double) {
        guard peaks.count > 3, duration > 0 else { return (0, 0) }
        let slice = duration / Double(peaks.count)
        var lead = 0
        while lead < peaks.count, peaks[lead] < threshold { lead += 1 }
        var trail = 0
        while trail < peaks.count - lead, peaks[peaks.count - 1 - trail] < threshold { trail += 1 }
        let cap = duration / 3
        return (min(cap, Double(lead) * slice), min(cap, Double(trail) * slice))
    }
}

struct MusicChapter: Hashable, Identifiable, Sendable {
    var number: Int
    var title: String
    var performer: String?
    var start: Double
    var id: Int { number }
}

enum MusicCueSheet {
    /// "mm:ss:ff" with 75 frames to the second, the CUE format's own time.
    static func time(_ s: String) -> Double? {
        let p = s.split(separator: ":").compactMap { Double($0) }
        guard p.count == 3, p[2] < 75 else { return nil }
        return p[0] * 60 + p[1] + p[2] / 75
    }

    private static func quoted(_ rest: Substring) -> String {
        let t = rest.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("\""), let end = t.dropFirst().firstIndex(of: "\"") { return String(t[t.index(after: t.startIndex)..<end]) }
        return t
    }

    /// The tracks of a CUE sheet that describes ONE audio file (several FILE lines are not an image of one recording, so they give nothing). Each track starts at its INDEX 01.
    static func parse(_ text: String) -> [MusicChapter] {
        var files = 0, out: [MusicChapter] = []
        var number = 0, title = "", performer: String?, albumPerformer: String?
        var inTrack = false
        func flush(start: Double?) { if inTrack, let start { out.append(MusicChapter(number: number, title: title.isEmpty ? "Track \(number)" : title, performer: performer ?? albumPerformer, start: start)) } }
        var pendingStart: Double?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "\u{FEFF}")))
            let u = line.uppercased()
            if u.hasPrefix("FILE ") { files += 1 }
            else if u.hasPrefix("TRACK ") {
                flush(start: pendingStart)
                inTrack = true; pendingStart = nil; title = ""; performer = nil
                number = Int(line.split(separator: " ").dropFirst().first ?? "") ?? (number + 1)
            } else if u.hasPrefix("TITLE ") { if inTrack { title = quoted(line.dropFirst(6)) } }
            else if u.hasPrefix("PERFORMER ") { let v = quoted(line.dropFirst(10)); if inTrack { performer = v } else { albumPerformer = v } }
            else if u.hasPrefix("INDEX 01 ") { pendingStart = time(String(line.dropFirst(9)).trimmingCharacters(in: .whitespaces)) }
        }
        flush(start: pendingStart)
        guard files == 1 else { return [] }
        let sorted = out.sorted { $0.start < $1.start }
        return sorted.count >= 2 ? sorted : []
    }

    /// A CUE sheet named like the audio file, next to it.
    static func sidecar(for audio: URL) -> URL? {
        let cue = audio.deletingPathExtension().appendingPathExtension("cue")
        return FileManager.default.fileExists(atPath: cue.path) ? cue : nil
    }

    static func chapters(for audio: URL) -> [MusicChapter] {
        guard let u = sidecar(for: audio), let d = try? Data(contentsOf: u), d.count < 512_000 else { return [] }
        let text = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) ?? ""
        return parse(text)
    }

    /// The chapter playing at `position`.
    static func current(_ chapters: [MusicChapter], at position: Double) -> MusicChapter? { chapters.last { $0.start <= position + 0.05 } }
}
