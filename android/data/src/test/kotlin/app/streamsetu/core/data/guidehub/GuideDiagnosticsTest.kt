package app.streamsetu.core.data.guidehub

import app.streamsetu.core.data.db.GuideDiagnosticsEntity
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

class GuideDiagnosticsTest {
    private val now = Instant.parse("2026-11-22T12:00:00Z").toEpochMilli()
    private fun d(outcome: String, seen: Int = 0, kept: Int = 0, past: Int = 0, future: Int = 0, invalid: Int = 0, channels: Int = 0, mapped: Int = 0, lastStop: Long? = null, success: Long? = now - 1000) =
        GuideDiagnosticsEntity("g", now - 1000, success, outcome, channels = channels, mapped = mapped, programmesSeen = seen, programmesKept = kept, droppedPast = past, droppedFuture = future, droppedInvalid = invalid, fileLastStop = lastStop)
    private fun keys(e: GuideDiagnosticsEntity?, programmes: Int = 0, end: Long? = null): List<String> {
        val f = GuideDiagnosisAdvisor.freshness(e, true, programmes, end, 6, now)
        return GuideDiagnosisAdvisor.findings(e, f, now).map { it.key }
    }

    @Test fun neverFetchedAndFailed() {
        assertEquals(listOf("diag.neverFetched"), keys(null))
        assertEquals("diag.fetchFailed", keys(d("failed").copy(error = "boom")).first())
    }
    @Test fun emptyGuideIsExplained() {
        // The owner's case: a guide with channels and no programmes, three and a half days old.
        val owner = d("ok", channels = 448, success = now - 84 * 3600_000L)
        assertEquals("diag.emptyFile", keys(owner).first())
        assertEquals("diag.allPast", keys(d("empty", seen = 3, past = 3, lastStop = now - 4 * 86400_000L)).first())
        assertTrue(GuideDiagnosisAdvisor.findings(d("empty", seen = 3, past = 3, lastStop = now - 4 * 86400_000L), Freshness(FreshLevel.ERROR, "guide.empty", null), now).first().text.contains("4 days"))
        assertEquals("diag.allFuture", keys(d("empty", seen = 3, future = 3)).first())
        assertEquals("diag.invalidTimes", keys(d("empty", seen = 2, invalid = 2)).first())
        assertEquals("diag.partlyOutside", keys(d("empty", seen = 4, past = 2, future = 1, invalid = 1)).first())
    }
    @Test fun healthyAndUnmatched() {
        assertEquals(listOf("diag.ok"), keys(d("ok", seen = 10, kept = 10, channels = 5, mapped = 5), 10, now + 72 * 3600_000L))
        assertTrue(keys(d("ok", seen = 10, kept = 10, channels = 5, mapped = 0), 10, now + 72 * 3600_000L).contains("diag.noMapping"))
    }
    @Test fun messagesFillTheirPlaceholders() {
        assertEquals("The guide was last updated 3 days ago.", GuideMessages.render("guide.updatedLongAgo", 3))
        assertEquals("Only 4 of the guide's 900 channels are matched to your channels.", GuideMessages.render("diag.fewMapped", 4, 900))
        assertTrue(GuideMessages.render("diag.fetchFailed", "boom").endsWith("boom"))
    }
}
