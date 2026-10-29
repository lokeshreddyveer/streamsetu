package app.streamsetu.tv.sports.discovery

import app.streamsetu.core.data.db.SportsRecordingEntity
import app.streamsetu.core.sports.SportsEvent
import app.streamsetu.tv.sports.personal.SportsKeys
import app.streamsetu.tv.sports.recording.SportsRecordingStatus

/** The recordings the screens know about, looked up by event in one map read instead of a scan of every row for every card. */
class RecordingIndex(val rows: List<SportsRecordingEntity>) {
    private val byEvent = HashMap<String, SportsRecordingEntity>()
    private val bySlot = HashMap<String, SportsRecordingEntity>()

    init {
        // Open requests win over ended ones, then the most recently changed.
        for (r in rows.filter { it.status != SportsRecordingStatus.CANCELLED.name }.sortedWith(compareBy({ if (isOpen(it)) 0 else 1 }, { -it.updatedAt }, { it.id }))) {
            r.matchedEventId?.let { byEvent.putIfAbsent(it, r) }
            bySlot.putIfAbsent(slotKey(r.identity, r.slot), r)
        }
    }

    fun forEvent(e: SportsEvent): SportsRecordingEntity? = byEvent[e.id] ?: bySlot[slotKey(SportsKeys.identity(e), SportsKeys.slot(e.startMs))]

    companion object {
        fun isOpen(r: SportsRecordingEntity) = r.status == SportsRecordingStatus.SCHEDULED.name || r.status == SportsRecordingStatus.RECORDING.name || r.status == SportsRecordingStatus.REVIEW_REQUIRED.name
        fun slotKey(identity: String, slot: Long) = "$identity#$slot"
        val EMPTY = RecordingIndex(emptyList())
    }
}
