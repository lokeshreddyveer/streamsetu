package app.streamsetu.core.data.repo.smartmix

import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.db.Profiles
import app.streamsetu.core.data.repo.Visibility
import app.streamsetu.core.data.smartmix.*
import app.streamsetu.core.model.ContentKind
import kotlinx.coroutines.runBlocking

private fun Kind.ck() = if (this == Kind.SERIES) ContentKind.SERIES else ContentKind.MOVIE

/**
 * The Smart Mix [CandidateSource] over the identity tables. Every shelf reads a bounded, indexed slice of the catalog (about 2,000 library copies, never the whole library, never a
 * plot or an address), joins it to `content_identity` and marks, for each copy, whether it may be recommended:
 *  - a copy in a locked, hidden or adult-blocked folder is restricted; so is any copy whose identity matches one that is (another language, another playlist);
 *  - a copy whose identity was taken out of Continue Watching ("rec_dismissed") is dismissed.
 * The engine groups the copies and applies both again; this adapter may over-deliver but never under-flags. Continue Watching's own data is read only to know what was watched.
 *
 * Reads are blocking on purpose (the service runs on a background dispatcher). Each call costs a handful of indexed queries; the person's activity is cached for a few seconds and
 * dropped by [invalidate] when anything it was built from changes.
 */
class RoomCandidateSource(
    private val db: AppDatabase,
    private val visibility: Visibility,
    /** The open library's playlists, in the person's order. */
    private val sourceIds: () -> List<String>,
    /** The preferred audio language as a name ("tamil"), or null. */
    private val preferredLanguage: () -> String?,
    private val now: () -> Long = System::currentTimeMillis,
) : CandidateSource {

    private class Restriction(val folders: Map<ContentKind, Set<String>>, val keys: HashMap<String, MutableList<Int?>>, val snapshot: Visibility.Snapshot) {
        fun folderRestricted(kind: Kind, folder: String?) = folder != null && folder in (folders[kind.ck()] ?: emptySet())
        fun keyRestricted(key: String, year: Int?): Boolean {
            val years = keys[key] ?: return false
            return years.any { o -> if (year == null || o == null) (year == null && o == null) || key.contains(' ') else kotlin.math.abs(year - o) <= 1 }
        }
    }

    private class Activity(
        val at: Long, val profile: String, val restriction: Restriction,
        val watched: Map<String, Boolean>,          // identityKey -> completed
        val plays7: Map<String, Int>, val plays30: Map<String, Int>, val lastDays: Map<String, Int>,
        val dismissed: Map<String, List<Int?>>,
        val signals: Signals, val sourceRank: Map<String, Int>,
        val watchedItems: List<String>,
    ) {
        /** The newest copies of each playlist, read once and shared by every shelf built from this activity (they differ only in what they add to it). */
        val newest = HashMap<String, List<Candidate>>()
    }

    @Volatile private var cache: Activity? = null
    fun invalidate() { cache = null }

    private fun raw() = db.openHelper.readableDatabase

    private fun dayStart(): Long = java.time.LocalDate.now().atStartOfDay(java.time.ZoneId.systemDefault()).toInstant().toEpochMilli()

    // ---------------------------------------------------------------- activity (signals, restrictions, dismissals)

    private fun activity(): Activity {
        val t = now()
        cache?.takeIf { t - it.at < 5_000 }?.let { return it }
        val profile = Profiles.active(raw())
        val snap = runBlocking { visibility.snapshot(Visibility.Surface.RECOMMEND) }
        val restriction = Restriction(mapOf(ContentKind.MOVIE to snap.excluded(ContentKind.MOVIE), ContentKind.SERIES to snap.excluded(ContentKind.SERIES)), restrictedKeys(snap, runBlocking { db.sources().all() }.map { it.id }), snap)
        val sources = runBlocking { db.sources().all() }
        val rank = PreferredSource.rank(sources.map { PreferredSource.Info(it.id, it.enabled, it.draft, it.status == "FAILED", it.lastSyncAt, it.sortOrder) })

        // What was watched, by title (an episode counts for its series).
        val today = java.time.LocalDate.now().toEpochDay()
        val itemMs = HashMap<String, Long>(); val itemDay = HashMap<String, Long>(); val slots7 = HashMap<String, Int>(); val slots30 = HashMap<String, Int>()
        raw().query("SELECT itemId, kind, day, COUNT(*), SUM(ms) FROM watch_time WHERE day >= ? GROUP BY itemId, kind, day", arrayOf((today - 400).toString())).use { c ->
            while (c.moveToNext()) {
                val id = c.getString(0); val day = c.getLong(2); val n = c.getInt(3)
                itemMs.merge(id, c.getLong(4), Long::plus)
                itemDay.merge(id, day, ::maxOf)
                if (today - day < 7) slots7.merge(id, n, Int::plus)
                if (today - day < 30) slots30.merge(id, n, Int::plus)
            }
        }
        val completed = HashSet<String>(); val progressDay = HashMap<String, Long>()
        raw().query("SELECT itemId, completed, updatedAt FROM progress", emptyArray()).use { c ->
            while (c.moveToNext()) { val id = c.getString(0); if (c.getInt(1) != 0) completed += id; progressDay[id] = maxOf(progressDay[id] ?: 0L, c.getLong(2) / 86_400_000L) }
        }
        val episodeSeries = HashMap<String, String>()
        val episodeIds = (itemMs.keys + completed).toList()
        for (chunk in episodeIds.chunked(400)) raw().query("SELECT id, seriesId FROM episodes WHERE id IN (${chunk.joinToString(",") { "?" }})", chunk.toTypedArray()).use { c -> while (c.moveToNext()) episodeSeries[c.getString(0)] = c.getString(1) }
        fun title(id: String) = episodeSeries[id] ?: id
        val ms = HashMap<String, Long>(); val done = HashSet<String>(); val p7 = HashMap<String, Int>(); val p30 = HashMap<String, Int>(); val last = HashMap<String, Long>()
        for ((id, v) in itemMs) ms.merge(title(id), v, Long::plus)
        for ((id, v) in slots7) p7.merge(title(id), v, Int::plus)
        for ((id, v) in slots30) p30.merge(title(id), v, Int::plus)
        for ((id, d) in itemDay) last.merge(title(id), d, ::maxOf)
        for ((id, d) in progressDay) last.merge(title(id), d, ::maxOf)
        for (id in completed) done += title(id)

        // Identity of what was watched (restricted ones left out: nothing derived from a locked or hidden title).
        val watchedIds = (ms.keys + done + last.keys).toList()
        class W(val key: String, val year: Int?, val lang: String?, val folderKey: String?, val kind: String)
        val ident = HashMap<String, W>()
        for (chunk in watchedIds.chunked(400)) raw().query(
            "SELECT ci.itemId, ci.kind, ci.identityKey, ci.year, ci.lang, ci.folderKey, COALESCE(m.categoryId, s.categoryId) FROM content_identity ci LEFT JOIN movies m ON m.id = ci.itemId LEFT JOIN series s ON s.id = ci.itemId WHERE ci.itemId IN (${chunk.joinToString(",") { "?" }})", chunk.toTypedArray()).use { c ->
            while (c.moveToNext()) {
                val kind = if (c.getString(1) == "SERIES") Kind.SERIES else Kind.MOVIE
                if (restriction.folderRestricted(kind, c.getString(6))) continue
                ident[c.getString(0)] = W(c.getString(2), if (c.isNull(3)) null else c.getInt(3), c.getString(4), c.getString(5), c.getString(1))
            }
        }
        val watched = HashMap<String, Boolean>(); val plays7 = HashMap<String, Int>(); val plays30 = HashMap<String, Int>(); val lastDays = HashMap<String, Int>()
        val langs = HashMap<String, Int>(); val folders = HashMap<String, Int>(); val decades = HashMap<Int, Int>()
        for ((id, w) in ident) {
            val isDone = id in done
            if (isDone || (ms[id] ?: 0L) >= 5 * 60_000L) watched.merge(w.key, isDone) { a, b -> a || b }
            p7[id]?.let { plays7.merge(w.key, it, Int::plus) }; p30[id]?.let { plays30.merge(w.key, it, Int::plus) }
            last[id]?.let { d -> val ago = (today - d).toInt().coerceAtLeast(0); lastDays.merge(w.key, ago, ::minOf) }
            val weight = (p30[id] ?: 0) + if (isDone) 2 else 1
            w.lang?.let { langs.merge(it, weight, Int::plus) }; w.folderKey?.let { folders.merge(it, weight, Int::plus) }; w.year?.let { decades.merge(it / 10 * 10, weight, Int::plus) }
        }
        val affinity = Affinity(langs.entries.sortedByDescending { it.value }.take(3).map { it.key }, folders.entries.sortedByDescending { it.value }.take(5).map { it.key }, emptyList(), decades.entries.sortedByDescending { it.value }.take(2).map { it.key })

        // Newest watched titles first, for "Because You Watched".
        val recent = ArrayList<String>()
        val order = last.entries.sortedByDescending { it.value }
        for ((id, _) in order) { val w = ident[id] ?: continue; if (w.key !in recent) recent += w.key; if (recent.size >= 8) break }

        val dismissed = HashMap<String, MutableList<Int?>>()
        raw().query("SELECT identityKey, year FROM rec_dismissed WHERE profileId = ?", arrayOf(profile)).use { c -> while (c.moveToNext()) dismissed.getOrPut(c.getString(0)) { ArrayList(1) } += if (c.isNull(1)) null else c.getInt(1) }

        val pref = preferredLanguage()?.let { Derive.languageName(it) ?: it.replaceFirstChar { ch -> ch.uppercase() } }
        return Activity(t, profile, restriction, watched, plays7, plays30, lastDays, dismissed, Signals(pref, affinity, recent), rank, watchedIds).also { cache = it }
    }

    /** Identities (key + year) of every copy in a restricted folder: another copy of the same title, in any folder, is restricted with it. */
    private fun restrictedKeys(snap: Visibility.Snapshot, allSources: List<String>): HashMap<String, MutableList<Int?>> {
        val out = HashMap<String, MutableList<Int?>>()
        for ((kind, table) in listOf(ContentKind.MOVIE to "movies", ContentKind.SERIES to "series")) {
            val folders = snap.excluded(kind).toList()
            // One playlist at a time, so the (playlist, folder) index answers it; every playlist in the database counts, not only the open library's (a copy in any of them restricts the title).
            for (src in allSources) for (chunk in folders.chunked(400)) raw().query(
                "SELECT ci.identityKey, ci.year FROM content_identity ci JOIN $table x ON x.id = ci.itemId WHERE x.sourceId = ? AND x.categoryId IN (${chunk.joinToString(",") { "?" }})", arrayOf(src) + chunk.toTypedArray()).use { c ->
                while (c.moveToNext()) out.getOrPut(c.getString(0)) { ArrayList(1) } += if (c.isNull(1)) null else c.getInt(1)
            }
        }
        return out
    }

    override fun signals(profileId: String): Signals = activity().signals

    // ---------------------------------------------------------------- pools

    private val cols = "ci.itemId, ci.kind, ci.sourceId, ci.identityKey, ci.year, ci.lang, ci.qualityRank, ci.isCam, ci.folderKey, x.categoryId, x.rating, x.addedAt, x.posterUrl IS NOT NULL AND x.posterUrl != ''"

    private fun movieSelect(where: String, order: String = "", limit: Int = 0) =
        "SELECT $cols, 0, x.title FROM movies x JOIN content_identity ci ON ci.itemId = x.id WHERE $where $order ${if (limit > 0) "LIMIT $limit" else ""}"
    private fun seriesSelect(where: String, order: String = "", limit: Int = 0) =
        "SELECT $cols, x.backdropUrl IS NOT NULL AND x.backdropUrl != '', x.title FROM series x JOIN content_identity ci ON ci.itemId = x.id WHERE $where $order ${if (limit > 0) "LIMIT $limit" else ""}"

    private fun read(sql: String, args: Array<String>, a: Activity, into: LinkedHashMap<String, Candidate>) {
        val start = dayStart()
        raw().query(sql, args).use { c ->
            while (c.moveToNext()) {
                val id = c.getString(0)
                if (id in into) continue
                val kind = if (c.getString(1) == "SERIES") Kind.SERIES else Kind.MOVIE
                val key = c.getString(3); val year = if (c.isNull(4)) null else c.getInt(4)
                val folder = c.getString(9)
                val addedAt = c.getLong(11)
                // Three ways to be restricted, none of which needs the other copy to have an identity row yet (it may not, while the identity is still being filled in): the folder, the identity of a
                // restricted copy, and the title rule (normalized title + year within one) over the titles of the restricted folders. Fail closed.
                val restricted = a.restriction.folderRestricted(kind, folder) || a.restriction.keyRestricted(key, year) || !a.restriction.snapshot.titleOk(kind.ck(), folder, c.getString(14), year)
                into[id] = Candidate(
                    id = id, kind = kind, identityKey = key, year = year,
                    addedDays = if (addedAt <= 0) null else ((start - addedAt) / 86_400_000L).toInt().coerceAtLeast(0),
                    ratingText = c.getString(10), qualityRank = c.getInt(6), isCam = c.getInt(7) != 0, lang = c.getString(5), folderKey = c.getString(8),
                    hasPoster = c.getInt(12) != 0, hasBackdrop = c.getInt(13) != 0,
                    watched = a.watched.containsKey(key), completed = a.watched[key] == true, lastWatchedDays = a.lastDays[key],
                    plays7 = a.plays7[key] ?: 0, plays30 = a.plays30[key] ?: 0,
                    restricted = restricted, dismissed = !restricted && a.dismissed[key]?.any { o -> year == null || o == null || kotlin.math.abs(year - o) <= 1 } == true,
                    sourceRank = a.sourceRank[c.getString(2)] ?: 0,
                )
            }
        }
    }

    private fun byIds(ids: Collection<String>, a: Activity, into: LinkedHashMap<String, Candidate>) {
        for (chunk in ids.chunked(400)) {
            val q = chunk.joinToString(",") { "?" }
            read(movieSelect("x.id IN ($q)"), chunk.toTypedArray(), a, into)
            read(seriesSelect("x.id IN ($q)"), chunk.toTypedArray(), a, into)
        }
    }

    override fun pool(request: PoolRequest): List<Candidate> {
        val a = activity()
        val spec = ShelfSpec.of(request.shelfId)
        val limit = request.limit.coerceIn(200, 2000)
        val into = LinkedHashMap<String, Candidate>()
        val sources = sourceIds().ifEmpty { return emptyList() }
        // The budget is shared between playlists (twin playlists do not double the pool).
        fun newest(movies: Int, series: Int, extraWhere: String = "", extraArgs: Array<String> = emptyArray()) {
            val cacheKey = "$movies|$series|$extraWhere|${extraArgs.joinToString(",")}|${sources.joinToString(",")}"
            a.newest[cacheKey]?.let { cached -> cached.forEach { into[it.id] = it }; return }
            val local = LinkedHashMap<String, Candidate>()
            for (s in sources) {
                read(movieSelect("x.sourceId = ? $extraWhere", "ORDER BY x.addedAt DESC", (movies / sources.size).coerceAtLeast(50)), arrayOf(s) + extraArgs, a, local)
                read(seriesSelect("x.sourceId = ? $extraWhere", "ORDER BY x.addedAt DESC", (series / sources.size).coerceAtLeast(30)), arrayOf(s) + extraArgs, a, local)
            }
            a.newest[cacheKey] = local.values.toList()
            into.putAll(local)
        }
        when {
            spec.isFolder -> {
                val k = spec.folderKey!!
                read(movieSelect("ci.folderKey = ?", "ORDER BY x.addedAt DESC", limit), arrayOf(k), a, into)
                read(seriesSelect("ci.folderKey = ?", "ORDER BY x.addedAt DESC", limit), arrayOf(k), a, into)
            }
            request.shelfId == ShelfSpec.LANG_PREF -> {
                val l = a.signals.preferredLang
                if (l != null) newest(limit * 6 / 10, limit * 4 / 10, "AND ci.lang = ?", arrayOf(l))
            }
            request.shelfId == ShelfSpec.REDISCOVER -> {
                val done = ArrayList<String>()
                raw().query("SELECT itemId FROM progress WHERE completed = 1 ORDER BY updatedAt ASC LIMIT 1500", emptyArray()).use { c -> while (c.moveToNext()) done += c.getString(0) }
                val seriesOf = ArrayList<String>()
                for (chunk in done.chunked(400)) raw().query("SELECT DISTINCT seriesId FROM episodes WHERE id IN (${chunk.joinToString(",") { "?" }})", chunk.toTypedArray()).use { c -> while (c.moveToNext()) seriesOf += c.getString(0) }
                byIds((done + seriesOf).distinct().take(limit), a, into)
            }
            request.shelfId == ShelfSpec.FOR_YOU -> {
                val seedKeys = request.seedIdentityKeys.ifEmpty { a.signals.recentWatchedIdentityKeys.take(4) }
                val folders = LinkedHashSet<String>(); val langs = LinkedHashSet<String>()
                for (chunk in seedKeys.chunked(400)) if (chunk.isNotEmpty()) raw().query("SELECT DISTINCT folderKey, lang FROM content_identity WHERE identityKey IN (${chunk.joinToString(",") { "?" }}) LIMIT 40", chunk.toTypedArray()).use { c ->
                    while (c.moveToNext()) { c.getString(0)?.let(folders::add); c.getString(1)?.let(langs::add) }
                }
                for (f in folders.take(8)) {
                    read(movieSelect("ci.folderKey = ?", "ORDER BY x.addedAt DESC", limit / 8), arrayOf(f), a, into)
                    read(seriesSelect("ci.folderKey = ?", "ORDER BY x.addedAt DESC", limit / 16), arrayOf(f), a, into)
                }
                newest(limit / 4, limit / 8)
            }
            else -> {
                newest(limit * 6 / 10, limit * 4 / 10)
                if (request.shelfId == ShelfSpec.TOP_WEEK) {
                    // What is played most here, so the local list has real counts to rank by.
                    val top = ArrayList<String>()
                    raw().query("SELECT itemId FROM watch_time GROUP BY itemId ORDER BY SUM(ms) DESC LIMIT 400", emptyArray()).use { c -> while (c.moveToNext()) top += c.getString(0) }
                    byIds(top, a, into)
                }
            }
        }
        val out = ArrayList<Candidate>(into.values)
        // Other copies of the same titles (another language, another playlist): the group picks its representative among them and takes the restriction of any of them.
        val keys = out.map { it.identityKey }.distinct()
        val extra = LinkedHashMap<String, Candidate>()
        for (chunk in keys.take(1500).chunked(300)) {
            val q = chunk.joinToString(",") { "?" }
            read(movieSelect("ci.kind = 'MOVIE' AND ci.identityKey IN ($q)", "", 0), chunk.toTypedArray(), a, extra)
            read(seriesSelect("ci.kind = 'SERIES' AND ci.identityKey IN ($q)", "", 0), chunk.toTypedArray(), a, extra)
        }
        for ((id, c) in extra) if (id !in into) out += c
        return out
    }

    override fun matchCandidates(profileId: String): List<Candidate> = emptyList()

    /** Library copies whose identity key is one of [names] (the folded titles of a public trending list): a few dozen indexed lookups, never the whole library. */
    override fun matchCandidates(profileId: String, names: Set<String>): List<Candidate> {
        val a = activity()
        val into = LinkedHashMap<String, Candidate>()
        for (chunk in names.toList().chunked(300)) {
            val q = chunk.joinToString(",") { "?" }
            read(movieSelect("ci.kind = 'MOVIE' AND ci.identityKey IN ($q)"), chunk.toTypedArray(), a, into)
            read(seriesSelect("ci.kind = 'SERIES' AND ci.identityKey IN ($q)"), chunk.toTypedArray(), a, into)
        }
        return into.values.toList()
    }
}
