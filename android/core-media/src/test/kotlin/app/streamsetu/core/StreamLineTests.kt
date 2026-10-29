package app.streamsetu.core

import app.streamsetu.core.playback.StreamFacts
import app.streamsetu.core.playback.StreamLine
import app.streamsetu.core.playback.TrackOption
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class StreamLineTests {
    private fun t(id: String, label: String, lang: String?, sel: Boolean) = TrackOption(id, label, lang, sel)

    @Test fun qualityNamesFollowTheLargerOfHeightAndWidth() {
        assertEquals("4K", StreamLine.quality(3840, 2160))
        assertEquals("1080p", StreamLine.quality(1920, 1080))
        assertEquals("1080p", StreamLine.quality(1920, 800))   // a wide film cropped to a short frame
        assertEquals("720p", StreamLine.quality(1280, 720))
        assertEquals("480p", StreamLine.quality(720, 480))
        assertNull(StreamLine.quality(0, 0))
    }

    @Test fun codecsGetTheirFamiliarNames() {
        assertEquals("H.264", StreamLine.videoCodec("avc1.64001f"))
        assertEquals("HEVC", StreamLine.videoCodec("hevc"))
        assertEquals("Dolby Digital+", StreamLine.audioCodec("eac3"))
        assertEquals("AAC", StreamLine.audioCodec("mp4a.40.2"))
        assertNull(StreamLine.videoCodec(""))
    }

    @Test fun theLineJoinsOnlyWhatIsKnown() {
        val facts = StreamFacts(1920, 1080, "h264", "aac")
        val audio = listOf(t("a1", "Track 1", "en", true))
        val subs = listOf(t("s1", "English", "en", false))
        assertEquals("1080p · H.264 · English · Subs off", StreamLine.text(facts, audio, subs))
        assertEquals("1080p · H.264 · AAC", StreamLine.text(facts, emptyList(), emptyList()))
        assertEquals("", StreamLine.text(StreamFacts(), emptyList(), emptyList()))
    }

    @Test fun anOnSubtitleShowsItsLanguage() {
        val subs = listOf(t("s1", "English", "en", false), t("s2", "Telugu", "te", true))
        assertEquals("Telugu", StreamLine.subtitles(subs))
        assertNull(StreamLine.subtitles(emptyList()))
    }

    @Test fun aTrackThatOnlyHasANumberFallsBackToTheSoundFormat() {
        val numbered = listOf(t("a1", "Track 1", null, true))
        assertEquals("AAC", StreamLine.audio(StreamFacts(1920, 1080, "h264", "aac"), numbered))
        assertNull(StreamLine.audio(StreamFacts(), numbered))
        assertEquals("Director's commentary", StreamLine.trackName(listOf(t("a2", "Director's commentary", null, true))))
    }

    @Test fun aPickedSubtitleWithNoNameIsOnNotOff() {
        assertEquals("On", StreamLine.subtitles(listOf(t("s1", "Subtitle 1", null, true))))
        assertEquals("Off", StreamLine.subtitles(listOf(t("s1", "Subtitle 1", null, false))))
    }
}
