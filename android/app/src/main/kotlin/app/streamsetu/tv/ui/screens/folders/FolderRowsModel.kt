package app.streamsetu.tv.ui.screens.folders

import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.mutableStateMapOf
import app.streamsetu.core.data.db.FolderRecentEntity
import app.streamsetu.core.data.repo.smartmix.FolderNaming
import app.streamsetu.core.data.repo.smartmix.FolderRowsPlan
import app.streamsetu.core.model.*
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.ui.screens.section.Card
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit

/** One row of the Folders view. A locked row carries only its name and a lock: no count, no titles. */
data class FolderRow(val id: String, val folder: Folder?, val name: String, val count: Int, val locked: Boolean, val browse: Browse) { val key get() = "folder:$id" }

/** What a row shows once it has been read (about [FolderRowsModel.TILES] titles or channels, in a stable order). */
sealed interface RowTiles {
    data class Titles(val cards: List<Card>) : RowTiles
    data class Channels(val items: List<ChannelTileData>) : RowTiles
}
/** A channel in a row: what is on now and how far along it is (null when the guide has nothing for it). */
data class ChannelTileData(val channel: Channel, val now: String?, val progress: Float?)

/**
 * The Folders view of Movies, Series and Live TV: one row per folder, listed [PAGE] at a time, each row read only when it is first drawn (a bounded number kept), in the order of
 * [FolderRowsPlan]. State that makes coming back feel unchanged (the list's scroll position, each row's, the tile the remote was on) lives here, in the screen's ViewModel.
 * Nothing here shuffles: tiles are the folder's newest titles, or its channels in the playlist's order.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class FolderRowsModel(private val c: AppContainer, private val kind: ContentKind, private val scope: CoroutineScope, private val folders: Flow<List<Folder>>, private val countsReady: Flow<Boolean>) {
    companion object {
        /** The guide's clock: the real time moved back by the guide's own offset (minutes), as the Live TV list does. */
        fun guideNow(realNowMs: Long, offsetMinutes: Int) = realNowMs - offsetMinutes * 60_000L
        fun progress(nowMs: Long, startMs: Long, endMs: Long): Float = ((nowMs - startMs).toFloat() / (endMs - startMs).coerceAtLeast(1)).coerceIn(0f, 1f)
        const val PAGE = FolderRowsPlan.PAGE; const val TILES = 12; const val KEEP = 40; private const val FAV = "fav"; private const val RECENT = "recent" }

    private val limit = MutableStateFlow(PAGE)
    private val opened = MutableStateFlow<Map<String, Long>>(emptyMap())

    init { scope.launch { opened.value = runCatching { c.db.identity().recent(c.profiles.activeId.value).associate { it.categoryId to it.lastOpenedAt } }.getOrDefault(emptyMap()) } }

    /** Every row the person can have, in order (before paging). Live TV starts with Favorites and Recently Watched when they hold something. */
    private val all: Flow<List<FolderRow>> = combine(folders, opened, c.folders.restrictRev, c.user.favouriteIds(), c.user.recentChannelIds(1), countsReady) { a ->
        @Suppress("UNCHECKED_CAST") val fs = a[0] as List<Folder>; @Suppress("UNCHECKED_CAST") val rec = a[1] as Map<String, Long>; @Suppress("UNCHECKED_CAST") val favs = a[3] as Set<String>; @Suppress("UNCHECKED_CAST") val recentCh = a[4] as List<String>; val ready = a[5] as Boolean
        val lang = app.streamsetu.tv.ui.components.preferredLanguage(c)
        val unlocked = fs.filter { it.pref.locked }.map { it.id }.filter { c.folders.isUnlocked(it) }.toSet()
        val ordered = FolderRowsPlan.order(fs, rec, lang)
        val rows = ordered.map { f ->
            val locked = f.pref.locked && f.id !in unlocked
            FolderRow(f.id, f, f.pref.alias?.takeIf { it.isNotBlank() } ?: FolderNaming.clean(f.providerName), if (locked) 0 else f.count, locked, Browse.Folder(f.id))
        }.filter { it.locked || !ready || it.count > 0 }
        if (kind != ContentKind.CHANNEL) rows else buildList {
            if (favs.isNotEmpty()) add(FolderRow(FAV, null, "Favorites", 0, false, Browse.Favorites))
            if (recentCh.isNotEmpty()) add(FolderRow(RECENT, null, "Recently Watched", 0, false, Browse.Recent))
            addAll(rows)
        }
    }

    val total: StateFlow<Int> = all.map { it.size }.stateIn(scope, SharingStarted.WhileSubscribed(30_000), 0)
    /** The rows shown so far (the first page, then more as the end is neared). */
    val rows: StateFlow<List<FolderRow>> = combine(all, limit) { l, n -> l.take(n) }.stateIn(scope, SharingStarted.WhileSubscribed(30_000), emptyList())
    fun more() { if (limit.value < total.value) limit.value = limit.value + PAGE }

    // ---- what a row shows ----
    val tiles = mutableStateMapOf<String, RowTiles>()
    private val order = ArrayDeque<String>()
    private val loading = HashSet<String>()
    private val gate = Semaphore(2)
    private var generation = 0

    /** Reads a row's tiles the first time it is drawn; a row already read, or being read, is left alone. A locked row is never read. */
    fun load(row: FolderRow) {
        if (row.locked || tiles.containsKey(row.id) || !loading.add(row.id)) return
        val g = generation
        scope.launch {
            gate.withPermit {
                val t = runCatching { read(row) }.getOrNull()
                if (g == generation && t != null) {
                    tiles[row.id] = t; order.remove(row.id); order.addLast(row.id)
                    while (order.size > KEEP) tiles.remove(order.removeFirst())          // bounded: the oldest rows are read again if they are drawn again
                }
            }
            loading.remove(row.id)
        }
    }

    /** What may be recommended or browsed changed (a lock, a profile, another library, a playlist read): every row is read again as it is drawn. */
    fun reset() { generation++; tiles.clear(); order.clear(); loading.clear(); version.intValue = generation }
    /** Changes with every [reset]: a row that is on screen keys its read on it, so it is read again and does not stay a skeleton. */
    val version = androidx.compose.runtime.mutableIntStateOf(0)

    init {
        // What a row may hold changes with a lock, hide, adult filter, Kids mode, profile, library, a playlist read that removed titles, or the identity fill finishing.
        scope.launch { combine(c.folders.restrictRev, c.profiles.activeId, c.library.sourceIds) { a, b, d -> "$a|$b|$d" }.drop(1).collect { reset() } }
        scope.launch { app.streamsetu.core.data.repo.smartmix.IdentityStore.changes.collect { ch -> if (ch.removed > 0 || ch.bulk) reset() } }
    }

    private suspend fun read(row: FolderRow): RowTiles {
        val sources = c.library.sourceIds.value
        val restricted = c.folders.restrictedIdsNow(kind)
        // A few more than shown are read, so titles with a picture can come first (a row never starts with a blank tile; blank ones only fill up what is missing).
        fun List<Card>.posterFirst() = partition { !it.posterUrl.isNullOrBlank() }.let { (with, without) -> (with + without).take(TILES) }
        return when (kind) {
            ContentKind.MOVIE -> RowTiles.Titles(c.browse.moviesPage(row.browse, SortSpec(SortField.ADDED), TILES + 8, 0, sources, restricted).map { Card(it.id, it.title, it.posterUrl, it.year, it.rating, it.sourceId, movie = it) }.posterFirst())
            ContentKind.SERIES -> RowTiles.Titles(c.browse.seriesPage(row.browse, SortSpec(SortField.ADDED), TILES + 8, 0, sources, restricted).map { Card(it.id, it.title, it.posterUrl, it.year, it.rating, it.sourceId, series = it) }.posterFirst())
            else -> {
                val chs = c.browse.channelPage(row.browse, SortSpec.defaultFor(ContentKind.CHANNEL), TILES, 0)
                val guide = runCatching { c.epg.resolve(chs) }.getOrDefault(emptyMap())
                // The guide's own time offset (Settings) applies, as on the Live TV list and the guide: the clock is moved back by it before the programmes are looked up and measured.
                val now = guideNow(System.currentTimeMillis(), c.ui.epgOffsetMinutes.value)
                val live = runCatching { c.epg.nowFor(guide.values.distinct(), now) }.getOrDefault(emptyMap())
                RowTiles.Channels(chs.map { ch ->
                    val p = guide[ch.id]?.let { live[it] }
                    ChannelTileData(ch, p?.title, p?.let { progress(now, it.startMs, it.endMs) })
                })
            }
        }
    }

    /** A folder was opened from a row: it comes earlier next time. */
    fun opened(row: FolderRow) {
        if (row.folder == null) return
        val now = System.currentTimeMillis()
        opened.value = opened.value + (row.id to now)
        scope.launch { runCatching { c.db.identity().putRecent(FolderRecentEntity(c.profiles.activeId.value, row.id, now, 1)) } }
    }

    // ---- coming back looks the same ----
    val listState = LazyListState()
    private val rowStates = HashMap<String, LazyListState>()
    /** The horizontal position of a row, kept for the rows most recently drawn. */
    fun rowState(id: String): LazyListState = rowStates.getOrPut(id) { LazyListState().also { if (rowStates.size > KEEP * 2) rowStates.keys.firstOrNull { k -> k != id }?.let(rowStates::remove) } }
    /** The row and tile the remote (or the finger) was last on, so Back from a folder returns to it. */
    var focused: Pair<String, String>? = null
    var restoreFocus = false
    /** True while a folder that was opened from a row is on screen, so Back returns to the rows. */
    var openedFromRow = false
}
