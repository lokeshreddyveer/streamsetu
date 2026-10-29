package app.streamsetu.core.sports

import app.streamsetu.core.model.Channel
import app.streamsetu.core.model.EpgProgram
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

/**
 * What the person using the app now may see. Passed with every request and part of the cache key, so a profile switch or a filter change can never be answered from another person's results.
 * On Android "locked" means what the app restricts: channels the person hid, folders locked with the PIN and not unlocked right now (FolderRepository.lockedIds, which relock on a profile switch, when the
 * library is left and after the relock time), and, while the adult filter or kids mode is on, folders with adult names.
 */
data class SportsContext(
    val profileId: String,
    /** The adult filter or kids mode is on. */
    val restricting: Boolean,
    val lockedCategoryIds: Set<String>,
    val hiddenChannelIds: Set<String>,
) {
    /** Why a channel must stay out of every result, or null when it may be used. */
    fun restriction(channel: Channel): SportsRestriction? = when {
        channel.id in hiddenChannelIds -> SportsRestriction.HIDDEN_CHANNEL
        restricting && channel.categoryId != null && channel.categoryId in lockedCategoryIds -> SportsRestriction.LOCKED_FOLDER
        else -> null
    }
    val fingerprint: String get() = SportsEventService.hash("$profileId|$restricting|${lockedCategoryIds.sorted().joinToString(",")}|${hiddenChannelIds.sorted().joinToString(",")}")
}

/**
 * Builds sports events from the guide of the person's own playlists. Channels are read once and programmes in a few large batches per playlist (never a query per channel or per row), off the main
 * thread, inside a bounded window, and the work stops when something newer replaces it. Each playlist's classified programmes are cached on their own, keyed by that playlist's revision, its channel
 * list, the person's profile and restrictions and the window, so another playlist's update does not invalidate them. Only channels the person may see are ever classified, so nothing in the cache is
 * unauthorised. Nothing is written to the database. Mirrors the Swift SportsEventService.
 */
class SportsEventService(private val inputs: Inputs, private val startToleranceMs: Long = 45 * 60_000L) {
    interface Inputs {
        /** Channels that have a guide id (hidden ones are omitted by the catalogue; the context is applied again here). */
        suspend fun channels(): List<Channel>
        /** The programmes overlapping [fromMs, toMs) for these channels, by channel id. */
        suspend fun programmes(channels: List<Channel>, fromMs: Long, toMs: Long): Map<String, List<EpgProgram>>
        /**
         * Each enabled playlist's guide revision. Android keeps one shared guide table (not one per playlist), so the revision a caller supplies should include a stamp of that shared guide as well as the
         * playlist's own last read; see [standard].
         */
        suspend fun revisions(): Map<String, String>
    }

    private data class SourceKey(val source: String, val revision: String, val channels: String, val context: String, val from: Long, val to: Long)
    class Hit(val match: SportsClassifier.Match, val channel: Channel, val programme: EpgProgram)

    private val lock = Any()
    private val cache = LinkedHashMap<SourceKey, List<Hit>>()
    private var generation = 0
    private var latestContext: String? = null
    @Volatile var classifiedSources = 0; private set
    /** How many classified playlist results are held; never more than [CACHE_LIMIT]. */
    val cachedEntries: Int get() = synchronized(lock) { cache.size }

    /** Drops everything cached and stops work in flight (a playlist was removed, the guide was rebuilt…). */
    fun invalidate() = synchronized(lock) { generation++; cache.clear() }

    /** Call when the profile, the adult filter or kids mode changes: work for the previous state is cancelled and can never be published. */
    fun contextDidChange() = synchronized(lock) { generation++; Unit }

    /** Events overlapping [fromMs, toMs) (limited to 72 hours), for this person. Throws [CancellationException] when superseded. */
    suspend fun events(fromMs: Long, toMs: Long, context: SportsContext, fastReject: Boolean = true): List<SportsEvent> = withContext(Dispatchers.Default) {
        val endMs = minOf(toMs, fromMs + MAX_WINDOW_MS)
        val fp = context.fingerprint
        val myGeneration = synchronized(lock) { if (latestContext != null && latestContext != fp) generation++; latestContext = fp; generation }
        val from = floorDiv(fromMs, 900_000L); val to = -floorDiv(-endMs, 900_000L)
        val revisions = inputs.revisions()
        val channels = inputs.channels().filter { context.restriction(it) == null }          // restricted channels are removed before anything is built
        val bySource = channels.groupBy { it.sourceId }

        val keys = HashMap<String, SourceKey>(); val missing = ArrayList<String>()
        for ((source, list) in bySource) {
            val k = SourceKey(source, revisions[source] ?: "none", fingerprint(list), fp, from, to)
            keys[source] = k
            if (synchronized(lock) { cache[k] } == null) missing.add(source)
        }
        val fresh = HashMap<String, List<Hit>>()
        for (source in missing) {
            currentCoroutineContext().ensureActive()
            fresh[source] = classify(bySource.getValue(source), from * 900_000L, to * 900_000L, myGeneration, fastReject)
        }
        // a different person, a filter change or an invalidation arrived while this ran: nothing from this run is published
        synchronized(lock) {
            if (generation != myGeneration) throw CancellationException("superseded")
            if (missing.isNotEmpty()) classifiedSources += missing.size
            for ((source, hits) in fresh) { val k = keys.getValue(source); cache.remove(k); cache[k] = hits }
            while (cache.size > CACHE_LIMIT) cache.remove(cache.keys.first())
        }
        val all = keys.values.flatMap { k -> synchronized(lock) { cache[k] } ?: fresh[k.source].orEmpty() }
        group(all, revisions, startToleranceMs).filter { it.endMs > fromMs && it.startMs < endMs }
    }

    private suspend fun classify(channels: List<Channel>, fromMs: Long, toMs: Long, myGeneration: Int, fastReject: Boolean): List<Hit> {
        val byId = channels.associateBy { it.id }
        val hits = ArrayList<Hit>()
        for (chunk in channels.chunked(BATCH)) {
            currentCoroutineContext().ensureActive()
            if (synchronized(lock) { generation } != myGeneration) throw CancellationException("superseded")
            for ((cid, list) in inputs.programmes(chunk, fromMs, toMs)) {
                val channel = byId[cid] ?: continue
                for (p in list) {
                    if (p.endMs <= fromMs || p.startMs >= toMs || p.endMs <= p.startMs) continue
                    val m = SportsClassifier.classify(title = p.title, channelName = channel.name, fastReject = fastReject) ?: continue
                    hits.add(Hit(m, channel, p))
                }
            }
        }
        return hits
    }

    companion object {
        const val MAX_WINDOW_MS = 72 * 3_600_000L
        const val BATCH = 500
        const val CACHE_LIMIT = 24

        /** Rounds towards negative infinity (java.lang.Math.floorDiv needs Android 7; this app supports Android 5.1). */
        internal fun floorDiv(a: Long, b: Long): Long { val q = a / b; return if (a % b != 0L && ((a < 0) != (b < 0))) q - 1 else q }

        private fun fingerprint(channels: List<Channel>): String =
            hash(channels.map { "${it.id}|${it.epgId.orEmpty()}|${it.categoryId.orEmpty()}|${it.name}|${it.catchupDays}" }.sorted().joinToString("\n"))

        /**
         * Feeds of one event: the same sport and identity, a compatible competition, and programmes that overlap or start within the tolerance of each other (across playlists too). Grouping (which feeds
         * belong together) is separate from identity (the event's id): the id never depends on which feed happens to start earliest.
         */
        fun group(hits: List<Hit>, revisions: Map<String, String>, toleranceMs: Long): List<SportsEvent> {
            val events = ArrayList<SportsEvent>()
            for ((identity, list) in hits.groupBy { it.match.identity }) {
                val sorted = list.sortedWith(compareBy({ it.programme.startMs }, { it.channel.id }))
                val clusters = ArrayList<MutableList<Hit>>()
                for (h in sorted) {
                    val i = clusters.indexOfLast { compatible(it, h, toleranceMs) }
                    if (i >= 0) clusters[i].add(h) else clusters.add(mutableListOf(h))
                }
                // The id comes from facts that survive a feed appearing, disappearing or being corrected by a few minutes: the normalized identity, the calendar day (UTC) of the event's reference time, and
                // which occurrence of that identity on that day it is. The reference time is the middle of the feeds' start times, not the earliest.
                class Ref(val cluster: List<Hit>, val ref: Long) { val day = floorDiv(ref, 86_400_000L) }
                val referenced = clusters.map { c -> val starts = c.map { it.programme.startMs }.sorted(); Ref(c, starts[(starts.size - 1) / 2]) }
                val perDay = HashMap<Long, Int>()
                for (r in referenced.sortedWith(compareBy({ it.ref }, { it.cluster.first().match.competitionKey.orEmpty() }, { it.cluster.first().channel.id }))) {
                    val ordinal = perDay[r.day] ?: 0; perDay[r.day] = ordinal + 1
                    events.add(makeEvent(r.cluster, revisions, hash("$identity|${r.day}|$ordinal")))
                }
            }
            return events.sortedWith(compareBy({ it.startMs }, { it.title }, { it.id }))
        }

        private fun compatible(cluster: List<Hit>, h: Hit, toleranceMs: Long): Boolean {
            val first = cluster.first()
            val c = cluster.firstNotNullOfOrNull { it.match.competitionKey }
            if (c != null && h.match.competitionKey != null && c != h.match.competitionKey) return false
            val start = cluster.minOf { it.programme.startMs }; val end = cluster.maxOf { it.programme.endMs }
            val overlaps = h.programme.startMs < end && h.programme.endMs > start
            return overlaps || Math.abs(h.programme.startMs - first.programme.startMs) <= toleranceMs
        }

        private fun qualityRank(q: String?) = mapOf("4K" to 4, "FHD" to 3, "HD" to 2, "SD" to 1)[q] ?: 0

        private fun makeEvent(cluster: List<Hit>, revisions: Map<String, String>, id: String): SportsEvent {
            val anchor = cluster.minOf { it.programme.startMs }
            val byChannel = HashMap<String, Hit>()
            for (h in cluster) { val cur = byChannel[h.channel.id]; if (cur == null || Math.abs(h.programme.startMs - anchor) < Math.abs(cur.programme.startMs - anchor)) byChannel[h.channel.id] = h }
            val hits = byChannel.values.sortedWith(compareByDescending<Hit> { qualityRank(it.match.quality?.value) }.thenBy { it.channel.name }.thenBy { it.channel.id })
            val feeds = hits.map { h ->
                SportsFeed(h.channel.id, h.channel.sourceId, h.channel.name, h.match.language?.value, h.match.language?.source ?: MetadataSource.UNKNOWN, h.match.quality?.value,
                    h.match.quality?.source ?: MetadataSource.UNKNOWN, h.match.variant, h.channel.epgId.orEmpty(), h.programme.startMs, h.channel.catchupDays > 0, h.channel.logoUrl)
            }
            val best = cluster.map { it.match }.maxByOrNull { it.confidence }!!
            val end = minOf(cluster.maxOf { it.programme.endMs }, anchor + 12 * 3_600_000L)
            fun commonest(values: List<String>) = values.groupingBy { it }.eachCount().entries.sortedWith(compareBy({ -it.value }, { it.key })).firstOrNull()?.key
            val sources = feeds.map { it.sourceId }.toSet()
            val revision = sources.map { "${it.take(8)}:${revisions[it] ?: "none"}" }.sorted().joinToString(",")
            return SportsEvent(id, best.sport, best.kind, commonest(cluster.mapNotNull { it.match.competition }), best.participants, best.stage,
                commonest(cluster.map { it.match.title }) ?: best.title, anchor, end, feeds, best.confidence, sources, revision)
        }

        /** FNV-1a: stable across runs and platforms. */
        fun hash(s: String): String {
            var h = -0x340d631b7bdddcdbL          // 0xcbf29ce484222325
            for (b in s.toByteArray(Charsets.UTF_8)) { h = h xor (b.toLong() and 0xff); h *= 0x100000001b3L }
            return java.lang.Long.toHexString(h)
        }
    }
}
