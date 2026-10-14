package app.streamsetu.core.playback

/** The Mac's `PlaybackEnginePreference`: Automatic picks per stream; the others force one engine. */
enum class EnginePreference(val label: String) {
    AUTOMATIC("Automatic (recommended)"), EXOPLAYER("Android ExoPlayer"), MPV("MPV");
    companion object { fun from(s: String?) = entries.firstOrNull { it.name == s } ?: AUTOMATIC }
}

/** The Mac's `BufferingMode`. */
enum class BufferingMode(val label: String, val detail: String, val minMs: Int, val maxMs: Int, val startMs: Int, val rebufferMs: Int, val mpvCacheSecs: Int, val liveOffsetMs: Long = 8_000) {
    AUTOMATIC("Automatic", "A balanced buffer that suits most streams.", 20_000, 60_000, 1_500, 4_000, 20),
    LOW_LATENCY("Low latency (live)", "Stays close to the live edge. Less delay, more risk of stalls.", 5_000, 15_000, 800, 2_000, 4, 3_000),
    STANDARD("Standard", "A moderate buffer for steady connections.", 15_000, 45_000, 1_500, 4_000, 15),
    LARGE("Large buffer", "Keeps more ahead. Best for slow or unstable providers.", 40_000, 120_000, 2_500, 5_000, 60, 20_000);
    companion object { fun from(s: String?) = entries.firstOrNull { it.name == s } ?: AUTOMATIC }
}

