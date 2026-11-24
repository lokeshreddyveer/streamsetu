package app.streamsetu.tv

import app.streamsetu.core.model.SourceType
import app.streamsetu.tv.ui.screens.library.canTestSource
import org.junit.Assert.*
import org.junit.Test

/** Jellyfin and Emby may connect with an empty password; the other account-based sources still need theirs. */
class MediaServerFormRuleTests {
    @Test fun jellyfinAndEmbyAcceptAnEmptyPassword() {
        for (k in listOf(SourceType.JELLYFIN, SourceType.EMBY)) {
            assertTrue(canTestSource(k, "http://host:8096", "demo", ""))
            assertFalse(canTestSource(k, "", "demo", ""))
            assertFalse(canTestSource(k, "http://host:8096", " ", "x"))
        }
    }
    @Test fun xtreamAndPlexStillNeedAPassword() {
        assertFalse(canTestSource(SourceType.XTREAM, "http://h", "u", ""))
        assertTrue(canTestSource(SourceType.XTREAM, "http://h", "u", "p"))
        assertFalse(canTestSource(SourceType.PLEX, "http://h", "", ""))
    }
}
