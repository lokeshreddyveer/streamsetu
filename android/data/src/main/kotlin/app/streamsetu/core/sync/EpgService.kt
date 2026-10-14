package app.streamsetu.core.sync

import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.db.EpgEntity
import app.streamsetu.core.model.EpgProgram
import app.streamsetu.core.model.Source
import app.streamsetu.core.net.Http
import app.streamsetu.core.parse.XmltvParser
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.zip.GZIPInputStream

/** Keeps a short window of the programme guide: from now to about two days ahead. */
class EpgService(private val db: AppDatabase) {
    suspend fun refresh(source: Source, fallbackUrl: String?, headers: Map<String, String> = emptyMap()): Int = withContext(Dispatchers.IO) {
        val url = source.epgUrl ?: fallbackUrl ?: return@withContext 0
        val now = System.currentTimeMillis()
        var kept = 0
        val batch = ArrayList<EpgEntity>()
        val names = LinkedHashMap<String, String>()
        Http.get(url, source.userAgent, headers) { resp ->
            val raw = resp.body!!.byteStream().buffered()
            val input = if (url.endsWith(".gz")) GZIPInputStream(raw) else raw
            XmltvParser.parse(input, now - 3600_000, now + 48 * 3600_000, onChannel = { id, name -> names.putIfAbsent(name, id) }) { p ->
                batch += EpgEntity(p.channelEpgId, p.startMs, p.endMs, p.title, p.description); kept++
            }
        }
        // Retention: nothing older than an hour and nothing more than two days ahead is kept, so the guide cannot grow without limit.
        db.epg().prune(now - 3600_000)
        batch.chunked(1000).forEach { db.epg().put(it) }
        if (names.isNotEmpty()) db.extras().putEpgChannels(names.map { (n, id) -> app.streamsetu.core.data.db.EpgChannelEntity(id, app.streamsetu.core.data.repo.SearchText.normalize(stripQuality(n))) })
        cache = null
        kept
    }

    @Volatile private var cache: Pair<Set<String>, Map<String, String>>? = null

    private suspend fun lookup(): Pair<Set<String>, Map<String, String>> = cache ?: run {
        val ids = db.extras().epgIdsWithProgrammes().toSet()
        val byName = HashMap<String, String>()
        db.extras().epgChannels().forEach { if (it.epgId in ids) byName.putIfAbsent(it.nameNorm, it.epgId) }
        (ids to byName).also { cache = it }
    }

    /**
     * The guide id to use for each channel. A channel's own guide id is used when the guide has programmes for it; otherwise its name (without HD / FHD / 4K tags)
     * is matched to a guide channel's name. Channels with no match are left out, and nothing is guessed beyond an exact name.
     */
    suspend fun resolve(channels: List<app.streamsetu.core.model.Channel>): Map<String, String> {
        val (ids, byName) = lookup()
        val out = HashMap<String, String>()
        for (ch in channels) {
            val own = ch.epgId
            if (own != null && own in ids) out[ch.id] = own
            else byName[app.streamsetu.core.data.repo.SearchText.normalize(stripQuality(ch.name))]?.let { out[ch.id] = it }
        }
        return out
    }

    /** What is on now for each channel id. */
    suspend fun nowFor(epgIds: List<String>, now: Long = System.currentTimeMillis()): Map<String, EpgProgram> {
        if (epgIds.isEmpty()) return emptyMap()
        return epgIds.chunked(500).flatMap { db.epg().nowFor(it, now) }.associate { it.channelEpgId to EpgProgram(it.channelEpgId, it.startMs, it.endMs, it.title, it.description) }
    }
}

/** The programmes of a channel from now on, for the guide screen. */
suspend fun EpgService.upcoming(db: AppDatabase, epgId: String, limit: Int = 3, now: Long = System.currentTimeMillis()): List<EpgProgram> =
    db.epg().upcoming(epgId, now, limit).map { EpgProgram(it.channelEpgId, it.startMs, it.endMs, it.title, it.description) }

/** Programmes of the given guide ids that overlap [fromMs, toMs), grouped by guide id, for the TV Guide timeline. */
suspend fun EpgService.window(db: AppDatabase, epgIds: List<String>, fromMs: Long, toMs: Long): Map<String, List<EpgProgram>> =
    if (epgIds.isEmpty()) emptyMap() else epgIds.chunked(400).flatMap { db.epg().window(it, fromMs, toMs) }.map { EpgProgram(it.channelEpgId, it.startMs, it.endMs, it.title, it.description) }.groupBy { it.channelEpgId }

suspend fun EpgService.programmeCount(db: AppDatabase): Int = db.epg().count()

/** "Star Sports 1 HD" and "Star Sports 1 FHD" are the same channel for guide purposes. */
fun stripQuality(name: String): String = name.replace(Regex("""(?i)\b(uhd|4k|fhd|hd|sd|raw|hevc|h265|h264|1080p|720p|50fps|60fps)\b"""), " ").replace(Regex("""\s+"""), " ").trim()
