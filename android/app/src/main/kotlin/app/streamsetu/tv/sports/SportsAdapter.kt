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
class SportsGuideInputs(
    private val db: AppDatabase,
    private val epg: EpgService,
    private val offsetMs: () -> Long = { 0L },
    /** The sources of the library that is open (LibraryRepository.sourceIds); null reads every enabled playlist. Sports shows what the rest of the app shows, so it follows the open library. */
    private val activeSourceIds: (() -> List<String>)? = null,
) : SportsEventService.Inputs {
    /**
     * The playlists Sports reads. With an active library given, exactly its sources and nothing else, as Movies, Series and Live TV read them (BrowseRepository uses the library's source ids as they
     * are, and an empty list means nothing is shown). Without one, every enabled playlist.
     */
    private suspend fun enabledSourceIds(): List<String> =
        activeSourceIds?.invoke() ?: db.sources().all().filter { it.enabled && !it.draft }.map { it.id }

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
        fun service(db: AppDatabase, epg: EpgService, offsetMs: () -> Long = { 0L }, activeSourceIds: (() -> List<String>)? = null) = SportsEventService(SportsGuideInputs(db, epg, offsetMs, activeSourceIds))

        /**
         * What the person may see now, from the same sources the rest of the app uses: [profileId] is the active profile; [lockedFolderIds] are the folders that are PIN-locked and not unlocked right now
         * (FolderRepository.lockedIdsNow); [hideAdult] is the adult filter or kids mode (ParentalControls.hideAdult), which hides folders whose names are adult. The channels the person hid are read here too, so
         * a restricted channel is removed even if a caller forgot to filter it.
         */
        suspend fun context(db: AppDatabase, profileId: String, hideAdult: Boolean, lockedFolderIds: Set<String>, isAdultName: (String) -> Boolean): SportsContext {
            val adult = if (hideAdult) db.catalog().allCategories().filter { isAdultName(it.name) }.map { it.id }.toSet() else emptySet()
            val locked = lockedFolderIds + adult
            return SportsContext(profileId, restricting = locked.isNotEmpty(), lockedCategoryIds = locked, hiddenChannelIds = db.catalog().hiddenChannelIds().toSet())
        }
    }
}
