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
    suspend fun refresh(source: Source, fallbackUrl: String?): Int = withContext(Dispatchers.IO) {
        val url = source.epgUrl ?: fallbackUrl ?: return@withContext 0
        val now = System.currentTimeMillis()
        var kept = 0
        val batch = ArrayList<EpgEntity>()
        Http.get(url) { resp ->
            val raw = resp.body!!.byteStream().buffered()
            val input = if (url.endsWith(".gz")) GZIPInputStream(raw) else raw
            XmltvParser.parse(input, now - 3600_000, now + 48 * 3600_000) { p ->
                batch += EpgEntity(p.channelEpgId, p.startMs, p.endMs, p.title, p.description); kept++
            }
        }
        db.epg().prune(now - 3600_000)
        batch.chunked(1000).forEach { db.epg().put(it) }
        kept
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
