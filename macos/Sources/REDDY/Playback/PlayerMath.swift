import Foundation

/// The small calculations behind the phone player's gestures and labels, kept apart from the screen so they are tested.
enum PlayerMath {
    /// "1080p", "4K", "720p"; judged by either side so a wide film at 1920×804 still reads as 1080p.
    static func qualityLabel(width: Int, height: Int) -> String {
        if width >= 3500 || height >= 2000 { return "4K" }
        if width >= 2500 || height >= 1300 { return "1440p" }
        if width >= 1800 || height >= 1000 { return "1080p" }
        if width >= 1200 || height >= 700 { return "720p" }
        if width >= 800 || height >= 450 { return "480p" }
        return "\(height)p"
    }

    /// Where a horizontal swipe across the picture would land. A swipe across half the screen moves about two minutes; short swipes move a little.
    static func scrubTarget(position: Double, dragPoints: Double, screenWidth: Double, duration: Double) -> Double {
        guard screenWidth > 0, duration > 0 else { return position }
        let seconds = dragPoints / screenWidth * 240
        return min(max(0, position + seconds), max(0, duration - 1))
    }

    /// Repeated double taps on the same side add up: the second adds another step, the third another, within a short time.
    static func stackedSkip(previousTotal: Double, previousSide: Int, previousAt: Date?, side: Int, now: Date, step: Double = 10, window: TimeInterval = 1.2) -> Double {
        if let previousAt, previousSide == side, now.timeIntervalSince(previousAt) <= window { return previousTotal + step }
        return step
    }

    /// "+1:20" or "−0:45" for a scrub preview.
    static func signedClock(_ seconds: Double) -> String {
        let s = Int(abs(seconds).rounded())
        return (seconds < 0 ? "−" : "+") + String(format: "%d:%02d", s / 60, s % 60)
    }

    /// A short video format name from whatever the engine reports ("H.264 / AVC / MPEG-4 AVC / MPEG-4 PART 10" becomes "H.264").
    static func videoCodecLabel(_ raw: String) -> String {
        let r = raw.lowercased()
        if r.contains("hevc") || r.contains("h.265") || r.contains("h265") || r.contains("hvc1") || r.contains("hev1") { return "HEVC" }
        if r.contains("h.264") || r.contains("h264") || r.contains("avc") { return "H.264" }
        if r.contains("mpeg-2") || r.contains("mpeg2") { return "MPEG-2" }
        if r.contains("mpeg-4") || r.contains("mpeg4") { return "MPEG-4" }
        if r.contains("vp9") { return "VP9" }
        if r.contains("av1") { return "AV1" }
        let first = raw.split(separator: "/").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? raw
        return String(first.prefix(10)).uppercased()
    }

    /// A short sound format name ("ac3" becomes "AC-3", "eac3" "E-AC-3", "mp2" "MP2").
    static func audioCodecLabel(_ raw: String) -> String {
        let r = raw.lowercased()
        if r.contains("e-ac") || r.contains("eac3") || r.contains("ec-3") { return "E-AC-3" }
        if r.contains("ac-3") || r.contains("ac3") { return "AC-3" }
        if r.contains("aac") { return "AAC" }
        if r.contains("mp3") { return "MP3" }
        if r.contains("mp2") || r.contains("mpeg audio") || r.contains("mpeg-1 layer ii") { return "MP2" }
        if r.contains("dts") { return "DTS" }
        if r.contains("opus") { return "Opus" }
        if r.contains("flac") { return "FLAC" }
        let first = raw.split(separator: "/").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? raw
        return String(first.prefix(10)).uppercased()
    }

    /// True for a track name that says nothing ("Track 1", "Audio 2", "Stream 3", "1").
    static func isGenericTrackLabel(_ label: String) -> Bool {
        let t = label.trimmingCharacters(in: .whitespaces).lowercased()
        if t.isEmpty { return true }
        let words = ["track", "audio", "stream", "sound", "subtitle", "subtitles", "sub"]
        let rest = words.first { t.hasPrefix($0) }.map { String(t.dropFirst($0.count)).trimmingCharacters(in: .whitespaces) } ?? t
        return !rest.isEmpty && rest.allSatisfy(\.isNumber) || t.allSatisfy(\.isNumber)
    }
}
