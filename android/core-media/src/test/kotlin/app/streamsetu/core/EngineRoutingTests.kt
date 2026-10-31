package app.streamsetu.core

import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.TrackGroup
import androidx.media3.common.Tracks
import app.streamsetu.core.playback.*
import org.junit.Assert.*
import org.junit.Test

/** Which engine plays what: a movie in a Matroska file goes to ExoPlayer (it hands the picture straight to the screen), unless it cannot play every track of that file. */
class EngineRoutingTests {
    private val both = setOf(EngineKind.EXOPLAYER, EngineKind.MPV)

    private fun pick(c: StreamContainer, p: EnginePreference = EnginePreference.AUTOMATIC, live: Boolean = false, have: Set<EngineKind> = both) = EngineSelector.select(c, p, have, live)

    @Test fun aMovieInAMatroskaFileStartsInExoPlayer() = assertEquals(EngineKind.EXOPLAYER, pick(StreamContainer.MKV))

    @Test fun aLiveMatroskaStreamStaysInMpv() = assertEquals(EngineKind.MPV, pick(StreamContainer.MKV, live = true))

    @Test fun aviAndRtspStayInMpv() {
        assertEquals(EngineKind.MPV, pick(StreamContainer.AVI))
        assertEquals(EngineKind.MPV, pick(StreamContainer.RTSP))
    }

    @Test fun aChosenPlayerIsAlwaysHonoured() {
        assertEquals(EngineKind.MPV, pick(StreamContainer.MKV, EnginePreference.MPV))
        assertEquals(EngineKind.EXOPLAYER, pick(StreamContainer.AVI, EnginePreference.EXOPLAYER))
    }

    @Test fun withoutExoPlayerAMatroskaFileStillPlays() = assertEquals(EngineKind.MPV, pick(StreamContainer.MKV, have = setOf(EngineKind.MPV)))

    // ---- does ExoPlayer play every track of the file? -------------------------------------------------------------------------------

    private fun group(mime: String, support: Int, selected: Boolean = true): Tracks.Group {
        val f = Format.Builder().setSampleMimeType(mime).build()
        return Tracks.Group(TrackGroup(f), false, intArrayOf(support), booleanArrayOf(selected))
    }
    private val handled = C.FORMAT_HANDLED
    private val noDecoder = C.FORMAT_UNSUPPORTED_TYPE
    private val tooBig = C.FORMAT_EXCEEDS_CAPABILITIES

    @Test fun aFileWhoseVideoAndAudioAreSupportedPlaysInExoPlayer() =
        assertNull(ExoSupport.unplayable(Tracks(listOf(group(MimeTypes.VIDEO_H265, handled), group(MimeTypes.AUDIO_E_AC3, handled)))))

    @Test fun anAudioTrackNoDecoderCanPlayRoutesTheFileToMpv() =
        assertEquals("audio", ExoSupport.unplayable(Tracks(listOf(group(MimeTypes.VIDEO_H265, handled), group(MimeTypes.AUDIO_DTS, noDecoder, selected = false)))))

    @Test fun aPictureBeyondTheDecoderRoutesTheFileToMpv() =
        assertEquals("video", ExoSupport.unplayable(Tracks(listOf(group(MimeTypes.VIDEO_H265, tooBig, selected = false), group(MimeTypes.AUDIO_AAC, handled)))))

    @Test fun anExtraUnsupportedAudioTrackDoesNotMoveAFileThatHasASupportedOne() =
        assertNull(ExoSupport.unplayable(Tracks(listOf(group(MimeTypes.VIDEO_H264, handled), group(MimeTypes.AUDIO_AAC, handled), group(MimeTypes.AUDIO_DTS, noDecoder, selected = false)))))

    @Test fun subtitlesNeverDecideTheEngine() =
        assertNull(ExoSupport.unplayable(Tracks(listOf(group(MimeTypes.VIDEO_H264, handled), group(MimeTypes.AUDIO_AAC, handled), group(MimeTypes.TEXT_SSA, noDecoder, selected = false)))))

    @Test fun aFileWithNoSoundIsNotRefused() =
        assertNull(ExoSupport.unplayable(Tracks(listOf(group(MimeTypes.VIDEO_H264, handled)))))

    @Test fun trackInformationThatHasNotArrivedYetDecidesNothing() = assertNull(ExoSupport.unplayable(Tracks.EMPTY))
}
