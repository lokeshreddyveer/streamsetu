package app.streamsetu.core.sync

import kotlinx.coroutines.ensureActive
import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.db.EpgEntity
import app.streamsetu.core.model.EpgIds
import app.streamsetu.core.model.EpgProgram
import app.streamsetu.core.model.Source
import app.streamsetu.core.net.Http
import app.streamsetu.core.parse.XmltvParser
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.zip.GZIPInputStream

/** Keeps a short window of the programme guide: from now to about two days ahead. */
class EpgService(private val db: AppDatabase) {
    /** Raised each time a guide is read again, so anything remembered about the old guide knows to let go. */
    @Volatile var generation = 0
        private set

    suspend fun refresh(source: Source, fallbackUrl: String?, headers: Map<String, String> = emptyMap()): Int = withContext(Dispatchers.IO) {
        val url = source.epgUrl ?: fallbackUrl ?: return@withContext 0
        val now = System.currentTimeMillis()
        var kept = 0
        val batch = ArrayList<EpgEntity>(CHUNK)
        val names = LinkedHashMap<String, String>()
        // Old programmes go first and new ones are written as they are read, a chunk at a time, so a very large guide never has to fit in memory.
        db.epg().prune(now - 3600_000)
        fun flush() { if (batch.isNotEmpty()) { val part = batch.toList(); batch.clear(); kotlinx.coroutines.runBlocking { db.epg().put(part) } } }
        Http.get(url, source.userAgent, headers) { resp ->
            val raw = java.io.BufferedInputStream(resp.body!!.byteStream())
            // Gzip is recognised by its first two bytes, not by the file name: many providers serve it without a ".gz" suffix.
            raw.mark(2); val b0 = raw.read(); val b1 = raw.read(); raw.reset()
            val gzipped = b0 == 0x1f && b1 == 0x8b
            // A guide cannot use the device without limit: how much is read, how much it may grow when unpacked, how many programmes are looked at and how long it may take.
            val counted = GuideLimits.CountingStream(raw)
            val input = GuideLimits.Guard(if (gzipped) GZIPInputStream(counted) else counted, counted, gzipped, System.currentTimeMillis())
            var seen = 0
            XmltvParser.parse(input, now - 3600_000, now + 48 * 3600_000, onChannel = { id, name -> if (names.size < GuideLimits.MAX_CHANNELS) names.putIfAbsent(name, id) }) { p ->
                if (++seen > GuideLimits.MAX_PROGRAMMES) throw java.io.IOException("The guide has more programmes than this app reads (${GuideLimits.MAX_PROGRAMMES}).")
                batch += EpgEntity(EpgIds.scope(source.id, p.channelEpgId), p.startMs, p.endMs, p.title, p.description); kept++
                if (batch.size >= CHUNK) flush()
            }
        }
        // Retention: nothing older than an hour and nothing more than two days ahead is kept, so the guide cannot grow without limit.
        flush()
        if (names.isNotEmpty()) db.extras().putEpgChannels(names.map { (n, id) -> app.streamsetu.core.data.db.EpgChannelEntity(EpgIds.scope(source.id, id), app.streamsetu.core.data.repo.SearchText.normalize(stripQuality(n))) })
        cache = null
        generation++
        kept
    }

    private companion object { const val CHUNK = 1000 }

    /** The bounds a guide is read within. Generous for the largest real providers; a hostile or broken file hits them instead of the disk, the CPU or the database. */
    internal object GuideLimits {
        const val MAX_DOWNLOAD_BYTES = 250L * 1024 * 1024         // as sent (compressed or not)
        const val MAX_UNPACKED_BYTES = 1500L * 1024 * 1024        // after unzipping
        const val MAX_EXPANSION = 120                              // unpacked size may not exceed this many times what was sent (checked once enough has been read)
        const val MAX_PROGRAMMES = 3_000_000                       // programmes looked at, kept or not
        const val MAX_CHANNELS = 60_000
        const val MAX_MILLIS = 15 * 60_000L

        /** Counts the bytes that came over the network. */
        class CountingStream(private val inner: java.io.InputStream) : java.io.InputStream() {
            @Volatile var count = 0L
            override fun read(): Int = inner.read().also { if (it >= 0) count++ }
            override fun read(b: ByteArray, off: Int, len: Int): Int = inner.read(b, off, len).also { if (it > 0) count += it }
            override fun close() = inner.close()
        }

        /** Reads what the parser reads, and stops with an error the moment a bound is passed. */
        class Guard(private val inner: java.io.InputStream, private val wire: CountingStream, private val gzipped: Boolean, private val started: Long) : java.io.InputStream() {
            private var unpacked = 0L
            private fun check(n: Int) {
                if (n <= 0) return
                unpacked += n
                if (wire.count > MAX_DOWNLOAD_BYTES) throw java.io.IOException("The guide is larger than ${MAX_DOWNLOAD_BYTES / 1_048_576} MB, so it was not read.")
                if (unpacked > MAX_UNPACKED_BYTES) throw java.io.IOException("The guide unpacks to more than ${MAX_UNPACKED_BYTES / 1_048_576} MB, so it was not read.")
                if (gzipped && unpacked > 8L * 1024 * 1024 && unpacked > wire.count * MAX_EXPANSION) throw java.io.IOException("The guide unpacks to far more than it was sent as, so it was not read.")
                if (System.currentTimeMillis() - started > MAX_MILLIS) throw java.io.IOException("The guide took longer than ${MAX_MILLIS / 60_000} minutes, so reading stopped.")
            }
            override fun read(): Int = inner.read().also { if (it >= 0) check(1) }
            override fun read(b: ByteArray, off: Int, len: Int): Int = inner.read(b, off, len).also { check(it) }
            override fun close() = inner.close()
        }
    }

    private class Lookup(val ids: Set<String>, val rawToStored: Map<String, String>, val byName: Map<String, String>, val byNameInSource: Map<String, String>)
    @Volatile private var cache: Lookup? = null

    private suspend fun lookup(): Lookup = cache ?: run {
        val ids = db.extras().epgIdsWithProgrammes().toSet()
        val rawToStored = HashMap<String, String>()
        ids.forEach { rawToStored.putIfAbsent(EpgIds.raw(it), it) }
        val byName = HashMap<String, String>(); val byNameInSource = HashMap<String, String>()
        db.extras().epgChannels().forEach {
            if (it.epgId !in ids) return@forEach
            byName.putIfAbsent(it.nameNorm, it.epgId)
            EpgIds.source(it.epgId)?.let { src -> byNameInSource.putIfAbsent(src + "\u0001" + it.nameNorm, it.epgId) }
        }
        Lookup(ids, rawToStored, byName, byNameInSource).also { cache = it }
    }

    /**
     * The guide id to use for each channel. A channel's own guide id is used when the guide has programmes for it, taken from its own playlist's guide first and from another
     * playlist's guide after that; otherwise its name (without HD / FHD / 4K tags) is matched to a guide channel's name, again its own playlist first. Channels with no match are
     * left out, and nothing is guessed beyond an exact name.
     */
    suspend fun resolve(channels: List<app.streamsetu.core.model.Channel>): Map<String, String> = withContext(Dispatchers.Default) {
        // The same channels against the same guide give the same answer, so opening the Guide again does not repeat the work for every channel.
        val startedAt = generation
        val key = fingerprint(channels)
        resolved?.takeIf { it.generation == startedAt && it.key == key }?.let { return@withContext it.map }
        val l = lookup()
        val out = HashMap<String, String>()
        var n = 0
        for (ch in channels) {
            if (++n % 500 == 0) this.ensureActive()          // a newer request cancels this one instead of letting it finish for nothing
            val own = ch.epgId
            val scoped = own?.let { EpgIds.scope(ch.sourceId, it) }
            val name = app.streamsetu.core.data.repo.SearchText.normalize(stripQuality(ch.name))
            val found = when {
                scoped != null && scoped in l.ids -> scoped
                own != null && own in l.ids -> own                       // a guide stored before ids were scoped
                own != null && l.rawToStored[own] != null -> l.rawToStored[own]
                else -> l.byNameInSource[ch.sourceId + "\u0001" + name] ?: l.byName[name]
            }
            if (found != null) out[ch.id] = found
        }
        if (generation == startedAt) resolved = Resolved(startedAt, key, out)
        out
    }

    private class Resolved(val generation: Int, val key: Long, val map: Map<String, String>)
    @Volatile private var resolved: Resolved? = null

    /** A cheap stand-in for "these are the same channels": the count and what decides each one's guide match (its id, guide id, playlist and name). */
    private fun fingerprint(channels: List<app.streamsetu.core.model.Channel>): Long {
        var h = channels.size.toLong()
        for (ch in channels) h = h * 31 + (ch.id.hashCode() * 31L + (ch.epgId?.hashCode() ?: 0)) * 31 + ch.sourceId.hashCode() * 17L + ch.name.hashCode()
        return h
    }

    /** What is on now for each channel id. */
    suspend fun nowFor(epgIds: List<String>, now: Long = System.currentTimeMillis()): Map<String, EpgProgram> {
        if (epgIds.isEmpty()) return emptyMap()
        return epgIds.chunked(500).flatMap { db.epg().nowFor(it, now) }.associate { it.channelEpgId to EpgProgram(it.channelEpgId, it.startMs, it.endMs, it.title, it.description) }
    }
}

/**
 * The one way the guide is read for channels: the programmes that overlap [fromMs, toMs) for each channel, given the guide id each one resolved to, with the guide time offset applied the same way
 * everywhere. The TV Guide (many channels) and the Live TV screen's own guide (one channel) both read through this, so they can never disagree.
 */
suspend fun EpgService.programmesFor(db: AppDatabase, channels: List<app.streamsetu.core.model.Channel>, guideIds: Map<String, String>, fromMs: Long, toMs: Long, offsetMs: Long): Map<String, List<EpgProgram>> {
    val data = window(db, channels.mapNotNull { guideIds[it.id] }.distinct(), fromMs - offsetMs, toMs - offsetMs)
    return channels.associate { ch -> ch.id to data[guideIds[ch.id]].orEmpty().map { it.copy(startMs = it.startMs + offsetMs, endMs = it.endMs + offsetMs) } }
}

/** What the guide holds for one channel. A channel that matched nothing and a read that failed are different answers, and neither is a guide with no programmes. */
sealed interface ChannelGuide {
    /** The channel matched a guide id; [programmes] may be empty if nothing is listed in the window. */
    class Matched(val guideId: String, val programmes: List<EpgProgram>) : ChannelGuide
    /** No guide id matched this channel (by its own id or its name). */
    object Unmatched : ChannelGuide
    class Failed(val why: String) : ChannelGuide
}

/** One channel's guide from 30 minutes before [nowMs] to three hours after, through the same path as the TV Guide. */
suspend fun EpgService.channelGuide(db: AppDatabase, ch: app.streamsetu.core.model.Channel, nowMs: Long, offsetMs: Long): ChannelGuide = try {
    val id = resolve(listOf(ch))[ch.id]
    if (id == null) ChannelGuide.Unmatched
    else ChannelGuide.Matched(id, programmesFor(db, listOf(ch), mapOf(ch.id to id), nowMs - 30 * 60_000L, nowMs + 3 * 3_600_000L, offsetMs)[ch.id].orEmpty())
} catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: Exception) { ChannelGuide.Failed(e.message ?: "The guide could not be read.") }

/** The programmes of a channel from now on, for the guide screen. */
suspend fun EpgService.upcoming(db: AppDatabase, epgId: String, limit: Int = 3, now: Long = System.currentTimeMillis()): List<EpgProgram> =
    db.epg().upcoming(epgId, now, limit).map { EpgProgram(it.channelEpgId, it.startMs, it.endMs, it.title, it.description) }

/** Programmes of the given guide ids that overlap [fromMs, toMs), grouped by guide id, for the TV Guide timeline. */
suspend fun EpgService.window(db: AppDatabase, epgIds: List<String>, fromMs: Long, toMs: Long): Map<String, List<EpgProgram>> =
    if (epgIds.isEmpty()) emptyMap() else epgIds.chunked(400).flatMap { db.epg().window(it, fromMs, toMs) }.map { EpgProgram(it.channelEpgId, it.startMs, it.endMs, it.title, it.description) }.groupBy { it.channelEpgId }

suspend fun EpgService.programmeCount(db: AppDatabase): Int = db.epg().count()

/** "Star Sports 1 HD" and "Star Sports 1 FHD" are the same channel for guide purposes. */
private val CHANNEL_PREFIX = Regex("""^\s*[A-Za-z0-9+&. ]{1,12}\s*(\|\||\||:|-)\s+(?=\S)""")
private val QUALITY_TAGS = Regex("""(?i)\b(uhd|4k|fhd|hd|sd|raw|hevc|h265|h264|1080p|720p|50fps|60fps)\b""")
private val SPACES = Regex("""\s+""")
fun stripQuality(name: String): String = name.replace(CHANNEL_PREFIX, "").replace(QUALITY_TAGS, " ").replace(SPACES, " ").trim()
