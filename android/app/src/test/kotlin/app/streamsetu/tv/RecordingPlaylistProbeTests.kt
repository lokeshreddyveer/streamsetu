package app.streamsetu.tv

import app.streamsetu.tv.record.RecordService
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RecordingPlaylistProbeTests {
    private fun looks(s: String) = RecordService.looksLikePlaylist(s.toByteArray(Charsets.ISO_8859_1))

    @Test fun aPlaylistIsRecognisedWhateverPrecedesIt() {
        assertTrue(looks("#EXTM3U\n#EXT-X-VERSION:3"))
        assertTrue(looks("\n\r\n  #EXTM3U"))
        assertTrue(RecordService.looksLikePlaylist(byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte()) + "#EXTM3U".toByteArray()))
    }

    @Test fun videoIsNotMistakenForOne() {
        assertFalse(looks(""))
        assertFalse(looks("#EXT"))
        assertFalse(RecordService.looksLikePlaylist(byteArrayOf(0x47, 0x40, 0x11, 0x10)))        // a transport stream starts with 0x47
        assertFalse(looks("<html>#EXTM3U"))
    }
}
