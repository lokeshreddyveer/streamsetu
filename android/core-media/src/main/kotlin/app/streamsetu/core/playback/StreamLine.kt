package app.streamsetu.core.playback

/** What the player knows about the stream on screen. Zero or null means not known yet. */
data class StreamFacts(val width: Int = 0, val height: Int = 0, val videoCodec: String? = null, val audioCodec: String? = null)

/** The short words for a stream's picture, sound and subtitles, shared by the pill over the picture and the chips in the controls. */
object StreamLine {
    /** "4K", "1080p", "720p"... A wide film is cropped to a short frame, so the width counts too. */
    fun quality(width: Int, height: Int): String? {
        if (width <= 0 && height <= 0) return null
        val h = maxOf(height, width * 9 / 16)
        return when {
            h >= 2000 -> "4K"
            h >= 1400 -> "1440p"
            h >= 1000 -> "1080p"
            h >= 700 -> "720p"
            h >= 560 -> "576p"
            h >= 460 -> "480p"
            else -> "${height.takeIf { it > 0 } ?: h}p"
        }
    }

    fun videoCodec(raw: String?): String? {
        val c = raw?.lowercase()?.trim().orEmpty()
        return when {
            c.isEmpty() -> null
            c.startsWith("hevc") || c.contains("h265") -> "HEVC"
            c.startsWith("avc") || c.contains("h264") -> "H.264"
            c.startsWith("av01") || c == "av1" -> "AV1"
            c.startsWith("vp9") -> "VP9"
            c.startsWith("mpeg2") || c.contains("mpeg2") -> "MPEG-2"
            else -> c.uppercase()
        }
    }

    fun audioCodec(raw: String?): String? {
        val c = raw?.lowercase()?.trim().orEmpty()
        return when {
            c.isEmpty() -> null
            c == "eac3" || c.contains("eac3") || c.contains("e-ac3") -> "Dolby Digital+"
            c == "ac3" || c.contains("ac-3") || c.endsWith("/ac3") -> "Dolby Digital"
            c.startsWith("mp4a") || c == "aac" -> "AAC"
            c.startsWith("mpeg") || c == "mp3" || c == "mp2" -> c.uppercase().removePrefix("MPEG")
            else -> c.uppercase()
        }
    }

    /** A label that only numbers the track ("Track 1", "Audio 2", "Subtitle") says nothing about it. */
    private val GENERIC = Regex("(?i)^(track|audio|stream|subtitles?|sub)\\s*#?\\d*$")

    /** The picked track's language when it has one, otherwise its label ("English", "Director's commentary"); null when nothing is picked or the label only numbers the track. */
    fun trackName(tracks: List<TrackOption>): String? =
        tracks.firstOrNull { it.selected }?.let { t -> languageName(t.language) ?: t.label.trim().takeIf { it.isNotBlank() && !GENERIC.matches(it) } }

    fun audio(facts: StreamFacts, tracks: List<TrackOption>): String? = trackName(tracks) ?: audioCodec(facts.audioCodec)

    /** "Off" when subtitles exist but none is on, "On" when one is on but says nothing about itself; null when the stream has none. */
    fun subtitles(tracks: List<TrackOption>): String? =
        if (tracks.isEmpty()) null else if (tracks.none { it.selected }) "Off" else trackName(tracks) ?: "On"

    /** The whole line: "1080p · H.264 · English · Subs off". Parts that are not known are left out. */
    fun text(facts: StreamFacts, audioTracks: List<TrackOption>, subtitleTracks: List<TrackOption>): String =
        listOfNotNull(quality(facts.width, facts.height), videoCodec(facts.videoCodec), audio(facts, audioTracks),
            subtitles(subtitleTracks)?.let { when (it) { "Off" -> "Subs off"; "On" -> "Subs on"; else -> it } }).joinToString(" · ")

    private fun languageName(code: String?): String? {
        val c = code?.trim().orEmpty()
        if (c.isEmpty() || c.equals("und", true)) return null
        val l = java.util.Locale.forLanguageTag(c.replace('_', '-'))
        return l.getDisplayLanguage(java.util.Locale.ENGLISH).takeIf { it.isNotBlank() && !it.equals(c, true) }
    }
}
