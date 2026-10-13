import Foundation

struct MPVConfiguration: Sendable {
    var hardwareDecoding = HardwareDecoding.automatic
    var deinterlace = false
    /// `hls-bitrate`: "no" lets mpv choose, "max"/"min" pin the highest/lowest variant of an adaptive stream.
    var hlsBitrate = "no"
    var cacheSeconds = 10
    var lowLatency = false
    var isLive = false
    /// This playlist's own headers, when it has any.
    var requestHeaders: [String: String] = [:]
    /// Keep played video so a live stream can be paused and rewound (costs memory, up to the two caps below).
    var liveRewind = false
    var httpProxy: String?
    var resumeThreshold = 1.5
    var renderingProfile = RenderingProfile.balanced
    var stereoDownmix = false
    var toneMapping = HDRToneMapping.automatic
    var preferredAudioLanguages: [String] = []
    var preferredSubtitleLanguages: [String] = []

    /// mpv ships a Lua script engine (LuaJIT) that wants to write executable memory. macOS's Hardened Runtime kills a
    /// process for that ("Invalid Page"), and REDDY draws its own UI, so all scripting is off. It also stops mpv from
    /// reading the user's own ~/.config/mpv files. Keep in sync with Scripts/HardenedMPVCheck.
    static let isolationOptions: [(String, String)] = [
        ("load-scripts", "no"), ("config", "no"), ("load-auto-profiles", "no"), ("load-osd-console", "no"),
        ("load-stats-overlay", "no"), ("ytdl", "no"), ("input-default-bindings", "no"), ("input-vo-keyboard", "no"),
        // Every other script libmpv ships and starts by itself (each is Lua, so each would be killed the same way):
        ("load-positioning", "no"), ("load-select", "no"), ("load-commands", "no"), ("load-console", "no"), ("load-context-menu", "no"),
    ]

    /// Option name/value pairs applied before `mpv_initialize`.
    var options: [(String, String)] {
        var o: [(String, String)] = Self.isolationOptions + [
            ("hwdec", hardwareDecoding.mpvValue),
            ("hls-bitrate", hlsBitrate),
            ("vo", "libmpv"),
            ("terminal", "no"),
            ("osc", "no"),
            ("keep-open", "yes"),
            ("volume-max", "130"),
            ("cache", "yes"),
            ("demuxer-max-bytes", "64MiB"),
            ("cache-secs", String(cacheSeconds)),
            ("deinterlace", deinterlace ? "yes" : "no"),
            ("network-timeout", "20"),
            ("user-agent", requestHeaders["User-Agent"] ?? "VLC/3.0.20 LibVLC/3.0.20"),
        ]
        let extra = requestHeaders.filter { $0.key != "User-Agent" }.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)".replacingOccurrences(of: ",", with: "%2C") }
        if !extra.isEmpty { o.append(("http-header-fields", extra.joined(separator: ","))) }
        o += renderingProfile.mpvOptions
        o += [("tone-mapping", toneMapping.mpvValue), ("sub-codepage", "auto")]
        if stereoDownmix { o.append(("audio-channels", "stereo")) }
        if let httpProxy { o.append(("http-proxy", httpProxy)) }
        // Reconnect by itself when the provider drops the connection, which IPTV servers do often, instead of stalling.
        o.append(("stream-lavf-o", "reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=4"))
        o.append(("cache-pause-wait", String(resumeThreshold)))
        if isLive && liveRewind {
            o += [("demuxer-max-bytes", "192MiB"), ("demuxer-max-back-bytes", "192MiB"), ("cache-secs", "900"), ("demuxer-readahead-secs", "900")]
        }
        if lowLatency { o += [("profile", "low-latency"), ("cache-pause", "no")] }
        if !preferredAudioLanguages.isEmpty { o.append(("alang", preferredAudioLanguages.joined(separator: ","))) }
        if !preferredSubtitleLanguages.isEmpty { o.append(("slang", preferredSubtitleLanguages.joined(separator: ","))) }
        return o
    }
}
