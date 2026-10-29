package app.streamsetu.tv.sports.recording

import org.junit.Assert.*
import org.junit.Test

class RecordingPolicyTests {
    private val h = 3_600_000L; private val min = 60_000L

    // ---- capacity right now

    @Test fun anUnknownProviderLimitMeansOneRecordingAtATime() {
        assertEquals(CapacityResult.OK, RecordingCapacity.now(0, recordingsOnSource = 0, recordingsTotal = 0, playingOnSource = 3, multiviewOnSource = 0))        // playback is not counted when the limit is unknown
        assertEquals(CapacityResult.CONNECTION_LIMIT, RecordingCapacity.now(0, 1, 1, 0, 0))
    }

    @Test fun aKnownProviderLimitCountsRecordingsPlaybackAndMultiviewTogether() {
        assertEquals("one connection, one stream playing", CapacityResult.CONNECTION_LIMIT, RecordingCapacity.now(1, 0, 0, 1, 0))
        assertEquals(CapacityResult.CONNECTION_LIMIT, RecordingCapacity.now(2, 1, 1, 0, 1)); assertEquals(CapacityResult.OK, RecordingCapacity.now(3, 1, 1, 0, 1))
    }

    @Test fun twoProvidersHaveTheirOwnLimitsAndTheDeviceAllowsTwo() {
        assertEquals("another provider is unaffected", CapacityResult.OK, RecordingCapacity.now(1, recordingsOnSource = 0, recordingsTotal = 1, playingOnSource = 0, multiviewOnSource = 0))
        assertEquals(CapacityResult.DEVICE_RECORDING_LIMIT, RecordingCapacity.now(5, 0, RecordingLimits.DEVICE_MAX, 0, 0))
    }

    // ---- capacity over a time window

    private fun w(src: String, from: Long, to: Long) = RecordingWindow(src, from, to)

    @Test fun anOverlapAloneIsNotAConflict() {
        assertEquals(CapacityResult.OK, RecordingCapacity.window(w("a", 0, 2 * h), listOf(w("b", h, 3 * h)), providerMax = 1))                    // different providers
        assertEquals(CapacityResult.OK, RecordingCapacity.window(w("a", 0, 2 * h), listOf(w("a", h, 3 * h)), providerMax = 2))                    // the provider allows two
    }

    @Test fun theSameUnknownProviderTwiceAtOnceIsAConnectionConflict() {
        assertEquals(CapacityResult.CONNECTION_LIMIT, RecordingCapacity.window(w("a", 0, 2 * h), listOf(w("a", h, 3 * h)), providerMax = 0))
        assertEquals("back to back is not an overlap", CapacityResult.OK, RecordingCapacity.window(w("a", 0, 2 * h), listOf(w("a", 2 * h, 3 * h)), providerMax = 0))
    }

    @Test fun threeAtOnceExceedsTheDevice() {
        assertEquals(CapacityResult.DEVICE_RECORDING_LIMIT, RecordingCapacity.window(w("c", 0, 3 * h), listOf(w("a", 0, 2 * h), w("b", h, 3 * h)), providerMax = 5))
        assertEquals("they only overlap one at a time", CapacityResult.OK, RecordingCapacity.window(w("c", 0, 3 * h), listOf(w("a", 0, h), w("b", 2 * h, 3 * h)), providerMax = 5))
    }

    // ---- storage

    private class Probe(var free: Long, var ok: Boolean = true) : StorageProbe { override fun freeBytes() = free; override fun writable() = ok }
    private val gb = 1024L * 1024 * 1024

    @Test fun theEstimateIsARangeByTheQualityTheNameHints() {
        val hd = RecordingStorage.estimate(2 * h, "HD"); val k = RecordingStorage.estimate(2 * h, "4K"); val unknown = RecordingStorage.estimate(2 * h, null)
        assertTrue(hd.lowBytes < hd.highBytes && hd.highBytes < k.lowBytes + 10 * gb); assertTrue("unknown quality gets the widest range", unknown.highBytes - unknown.lowBytes > hd.highBytes - hd.lowBytes)
        assertEquals(2 * h / 1000 * 3_000_000L / 8, hd.lowBytes)
    }

    @Test fun storageBlocksOnlyBelowTheLowestEstimatePlusTheReserve() {
        val e = RecordingStorage.estimate(2 * h, "HD")
        assertEquals(StorageVerdict.NOT_ENOUGH, RecordingStorage.verdict(e, Probe(e.lowBytes + RecordingStorage.RESERVE_BYTES - 1)))
        assertEquals("between the low and the high estimate it warns", StorageVerdict.UNCERTAIN, RecordingStorage.verdict(e, Probe(e.lowBytes + RecordingStorage.RESERVE_BYTES + 1)))
        assertEquals(StorageVerdict.OK, RecordingStorage.verdict(e, Probe(e.highBytes + RecordingStorage.RESERVE_BYTES + 1)))
        assertEquals(StorageVerdict.UNAVAILABLE, RecordingStorage.verdict(e, Probe(100 * gb, ok = false)))
    }

    // ---- start over and catch-up

    private val day = 86_400_000L

    @Test fun startOverNeedsALiveProgrammeInsideTheDeclaredArchiveOnAnXtreamChannel() {
        val start = 1_000 * h; val end = start + 3 * h
        assertTrue(SportsArchive.canStartOver(true, 3, start, end, start + 30 * min))
        assertFalse("not on an Xtream channel", SportsArchive.canStartOver(false, 3, start, end, start + 30 * min)); assertFalse("no archive declared", SportsArchive.canStartOver(true, 0, start, end, start + 30 * min))
        assertFalse("too soon after the start", SportsArchive.canStartOver(true, 3, start, end, start + 2 * min)); assertFalse("not live yet", SportsArchive.canStartOver(true, 3, start, end, start - min))
        assertFalse("beyond the archive window", SportsArchive.canStartOver(true, 1, start, end, start + 2 * day))
    }

    @Test fun catchUpNeedsAnEndedProgrammeInsideTheDeclaredArchive() {
        val start = 1_000 * h; val end = start + 2 * h
        assertTrue(SportsArchive.canWatchCatchUp(true, 3, start, end, end + h)); assertFalse("still live", SportsArchive.canWatchCatchUp(true, 3, start, end, end - min))
        assertFalse("expired", SportsArchive.canWatchCatchUp(true, 2, start, end, start + 3 * day)); assertFalse(SportsArchive.canWatchCatchUp(false, 3, start, end, end + h)); assertFalse(SportsArchive.canWatchCatchUp(true, 0, start, end, end + h))
    }
}
