package app.streamsetu.core.data

import app.streamsetu.core.sync.SyncProgress
import app.streamsetu.core.sync.SyncProgress.Stage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SyncProgressTests {
    @Test fun aStepWithATotalReadsLikeASentenceAndFillsABar() {
        val p = SyncProgress(Stage.SAVING_MOVIES, 12_000, 66_000)
        assertEquals("Saving movies 12,000 of 66,000", p.text()); assertEquals(12_000f / 66_000f, p.fraction!!, 0.0001f)
        assertEquals(1f, SyncProgress(Stage.SAVING_SERIES, 18_000, 18_000).fraction!!, 0f)
    }
    @Test fun aStepWithoutATotalOnlyCounts() {
        assertEquals("Reading movies 24,000", SyncProgress(Stage.READING_MOVIES, 24_000, 0).text()); assertNull(SyncProgress(Stage.READING_MOVIES, 24_000, 0).fraction)
        assertEquals("Signing in…", SyncProgress(Stage.SIGNING_IN, 0, 0).text())
    }
}
