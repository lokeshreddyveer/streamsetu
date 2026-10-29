package app.streamsetu.tv.sports.recording

import app.streamsetu.core.data.repo.StartOver

/** The limits on recording, in one place so a later Settings option can change them without touching Sports. Recording is a network-to-file copy, not a decoder: these are connection and device limits only. */
object RecordingLimits {
    /** Recordings running at once on this device. */
    const val DEVICE_MAX = 2
    /** Recordings running at once on one provider when the provider has not said how many connections it allows. */
    const val UNKNOWN_PROVIDER_MAX = 1
}

/** One recording's place in time on one provider (padding included). */
data class RecordingWindow(val sourceId: String, val fromMs: Long, val toMs: Long)

enum class CapacityResult { OK, CONNECTION_LIMIT, DEVICE_RECORDING_LIMIT }

object RecordingCapacity {
    /**
     * Whether one more recording may start right now. [providerMax] is what the provider says it allows (0 = it has not said). With a known limit, the recordings, the playback and the Multi-View tiles
     * on that provider all use its connections; with none, only the recordings on it are counted, and one is the limit. Nothing is ever stopped to make room.
     */
    fun now(providerMax: Int, recordingsOnSource: Int, recordingsTotal: Int, playingOnSource: Int, multiviewOnSource: Int): CapacityResult = when {
        recordingsTotal >= RecordingLimits.DEVICE_MAX -> CapacityResult.DEVICE_RECORDING_LIMIT
        providerMax > 0 && recordingsOnSource + playingOnSource + multiviewOnSource >= providerMax -> CapacityResult.CONNECTION_LIMIT
        providerMax <= 0 && recordingsOnSource >= RecordingLimits.UNKNOWN_PROVIDER_MAX -> CapacityResult.CONNECTION_LIMIT
        else -> CapacityResult.OK
    }

    /**
     * Whether a recording in [candidate] fits with the others that overlap it. Overlap alone is fine; it is a problem only if at some moment there would be more at once than the device allows, or
     * than the provider allows (playback cannot be predicted, so only the recordings are counted).
     */
    fun window(candidate: RecordingWindow, others: List<RecordingWindow>, providerMax: Int): CapacityResult {
        val overlapping = others.filter { it.fromMs < candidate.toMs && it.toMs > candidate.fromMs }
        if (overlapping.isEmpty()) return CapacityResult.OK
        // The busiest moment is at some start inside the candidate's window.
        val points = (listOf(candidate.fromMs) + overlapping.map { it.fromMs.coerceIn(candidate.fromMs, candidate.toMs) }).distinct()
        var maxTotal = 0; var maxSame = 0
        for (t in points) {
            val live = overlapping.filter { it.fromMs <= t && it.toMs > t }
            maxTotal = maxOf(maxTotal, live.size); maxSame = maxOf(maxSame, live.count { it.sourceId == candidate.sourceId })
        }
        val providerLimit = if (providerMax > 0) providerMax else RecordingLimits.UNKNOWN_PROVIDER_MAX
        return when {
            maxTotal + 1 > RecordingLimits.DEVICE_MAX -> CapacityResult.DEVICE_RECORDING_LIMIT
            maxSame + 1 > providerLimit -> CapacityResult.CONNECTION_LIMIT
            else -> CapacityResult.OK
        }
    }
}

/** How much space a recording is likely to need, as a range (the bitrate is not known; it is guessed from the quality the channel's name hints at). */
class StorageEstimate(val lowBytes: Long, val highBytes: Long)

/** Where recordings are written, and how much room there is. */
interface StorageProbe {
    fun freeBytes(): Long
    fun writable(): Boolean
}

enum class StorageVerdict { OK, UNCERTAIN, NOT_ENOUGH, UNAVAILABLE }

object RecordingStorage {
    /** Kept free beyond what a recording needs. */
    const val RESERVE_BYTES = 500L * 1024 * 1024

    /** Megabits per second, low and high, by the quality a channel's name hints at. A conservative spread; unknown quality gets the widest. */
    private fun mbps(quality: String?): Pair<Double, Double> = when (quality?.uppercase()) {
        "SD" -> 1.5 to 3.0; "HD" -> 3.0 to 6.0; "FHD" -> 5.0 to 10.0; "4K" -> 15.0 to 30.0
        else -> 2.0 to 10.0
    }

    fun estimate(durationMs: Long, quality: String?): StorageEstimate {
        val (lo, hi) = mbps(quality); val seconds = durationMs / 1000.0
        return StorageEstimate((lo * 1_000_000 / 8 * seconds).toLong(), (hi * 1_000_000 / 8 * seconds).toLong())
    }

    /** Blocks only when the destination cannot be written, or free space is below even the lowest estimate plus the reserve; warns when it is below the highest. */
    fun verdict(e: StorageEstimate, probe: StorageProbe): StorageVerdict {
        if (!probe.writable()) return StorageVerdict.UNAVAILABLE
        val free = probe.freeBytes()
        return when { free < e.lowBytes + RESERVE_BYTES -> StorageVerdict.NOT_ENOUGH; free < e.highBytes + RESERVE_BYTES -> StorageVerdict.UNCERTAIN; else -> StorageVerdict.OK }
    }
}

/** Whether the provider's archive can be offered for an event, from what the app knows. Provider-declared: the archive's existence is not confirmed, and playback failure is handled as it always is. */
object SportsArchive {
    /** Start Over: the programme is on now, the provider declares an archive covering it, this is an Xtream channel (the only kind the app can build an archive address for), and the app's own rules allow it. */
    fun canStartOver(xtream: Boolean, archiveDays: Int, programmeStartMs: Long, programmeEndMs: Long, nowMs: Long): Boolean =
        xtream && archiveDays > 0 && StartOver.canOffer(programmeStartMs, programmeEndMs, archiveDays, nowMs)

    /** Catch-up: the programme is over and still inside the declared archive window. */
    fun canWatchCatchUp(xtream: Boolean, archiveDays: Int, programmeStartMs: Long, programmeEndMs: Long, nowMs: Long): Boolean =
        xtream && archiveDays > 0 && nowMs >= programmeEndMs && nowMs - programmeStartMs <= archiveDays * 86_400_000L
}
