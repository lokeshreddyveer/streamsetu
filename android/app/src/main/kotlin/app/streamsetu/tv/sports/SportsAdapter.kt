package app.streamsetu.tv.sports

import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.repo.toModel
import app.streamsetu.core.model.Channel
import app.streamsetu.core.model.EpgIds
import app.streamsetu.core.model.EpgProgram
import app.streamsetu.core.sports.SportsContext
import app.streamsetu.core.sports.SportsEventService
import app.streamsetu.core.sync.EpgService
import app.streamsetu.core.sync.programmesFor

/**
 * Connects the Sports service to the real database: the channels of the enabled playlists that the person has not hidden, the guide through the same matching and time offset as the TV Guide, and
 * a guide revision for each playlist made from the part of the guide table that playlist actually reads from. Nothing is written; everything is derived and rebuildable.
 */
class SportsGuideInputs(private val db: AppDatabase, private val epg: EpgService, private val offsetMs: () -> Long = { 0L }) : SportsEventService.Inputs {
    private suspend fun enabledSourceIds(): List<String> = db.sources().all().filter { it.enabled && !it.draft }.map { it.id }

    override suspend fun channels(): List<Channel> {
        val sources = enabledSourceIds()
        return if (sources.isEmpty()) emptyList() else db.catalog().visibleChannelsOf(sources).map { it.toModel() }
    }

    override suspend fun programmes(channels: List<Channel>, fromMs: Long, toMs: Long): Map<String, List<EpgProgram>> {
        val guideIds = epg.resolve(channels)
        return epg.programmesFor(db, channels, guideIds, fromMs, toMs, offsetMs()).filterValues { it.isNotEmpty() }
    }

    /**
     * The guide is stored per playlist (each guide id carries the playlist it came from), so a playlist's revision is made from the guide of that playlist and of any other playlist its channels
     * actually take their programmes from, plus the guide time offset. Another playlist's guide refresh does not change it unless this playlist's channels read from it.
     */
    override suspend fun revisions(): Map<String, String> {
        val sources = enabledSourceIds()
        if (sources.isEmpty()) return emptyMap()
        val stamps = db.epg().guideStamps().associate { it.scope to "${it.n}:${it.lastEnd ?: 0}" }
        val byChannel = db.catalog().visibleChannelsOf(sources).map { it.toModel() }.groupBy { it.sourceId }
        val offset = offsetMs()
        return sources.associateWith { id ->
            val scopes = HashSet<String>(); scopes.add(id)
            val list = byChannel[id].orEmpty()
            if (list.isNotEmpty()) epg.resolve(list).values.forEach { scopes.add(EpgIds.source(it) ?: "") }
            "off=$offset|" + scopes.sorted().joinToString(",") { "$it=${stamps[it] ?: "none"}" }
        }
    }

    companion object {
        /** The service wired to the real database. */
        fun service(db: AppDatabase, epg: EpgService, offsetMs: () -> Long = { 0L }) = SportsEventService(SportsGuideInputs(db, epg, offsetMs))

        /**
         * What the person may see now. [profileId] is the active profile and [restricting] is the adult filter or kids mode (ParentalControls.hideAdult, which includes kids). The folders that count as
         * locked are the ones the app's own adult filter hides; the channels the person hid are read here too, so a restricted channel is removed even if a caller forgot to filter it.
         */
        suspend fun context(db: AppDatabase, profileId: String, restricting: Boolean, isAdultName: (String) -> Boolean): SportsContext {
            val locked = if (restricting) db.catalog().allCategories().filter { isAdultName(it.name) }.map { it.id }.toSet() else emptySet()
            return SportsContext(profileId, restricting, locked, db.catalog().hiddenChannelIds().toSet())
        }
    }
}
