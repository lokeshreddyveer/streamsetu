import Foundation

/// SoundCloud's own amplitude envelope of a track: a small JSON file (`{"width":1800,"height":140,"samples":[...]}`) on its media host.
/// Pure helpers; the picture is drawn by `SoundCloudWaveformBackdrop`.
enum SoundCloudWaveform {
    /// Only the media hosts SoundCloud serves these files from are fetched.
    static func isTrusted(_ url: URL) -> Bool {
        guard url.scheme == "https", let h = url.host?.lowercased() else { return false }
        return h == "sndcdn.com" || h.hasSuffix(".sndcdn.com")
    }

    /// Samples scaled to 0...1 by the file's own height (or its largest sample); an unreadable file gives nothing.
    static func samples(from data: Data) -> [Float] {
        guard let o = SoundCloudJSON.object(data), let raw = o["samples"] as? [Any], raw.count >= 8, raw.count <= 20_000 else { return [] }
        let values = raw.compactMap { ($0 as? NSNumber)?.floatValue }.map { max(0, $0) }
        guard values.count == raw.count else { return [] }
        let height = (o["height"] as? NSNumber)?.floatValue ?? 0
        let top = max(height, values.max() ?? 0)
        guard top > 0 else { return [] }
        return values.map { min(1, $0 / top) }
    }

    /// `count` bars from any number of samples: each bar is the loudest sample of its slice.
    static func bars(_ samples: [Float], count: Int) -> [Float] {
        guard !samples.isEmpty, count > 0 else { return [] }
        if samples.count <= count { return samples }
        return (0..<count).map { i in
            let lo = i * samples.count / count
            let hi = max(lo + 1, (i + 1) * samples.count / count)
            return samples[lo..<min(hi, samples.count)].max() ?? 0
        }
    }

    /// A track gets a waveform when it is a SoundCloud upload.
    static func isEligible(_ t: MusicTrack?) -> Bool { t?.providerID == SoundCloudProvider.providerID }
}
