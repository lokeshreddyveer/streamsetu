package app.streamsetu.core.data.guidehub

import app.streamsetu.core.data.db.*
import app.streamsetu.core.model.EpgIds
import app.streamsetu.core.net.Http
import app.streamsetu.core.net.HttpStatusException
import app.streamsetu.core.security.CredentialStore
import app.streamsetu.core.sync.EpgService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID
import java.util.zip.GZIPInputStream

/**
 * Guides the person added, mapping, the public channel database and diagnostics (the Android side of the Apple guide hub). A guide's programmes go into the shared `epg` table under the
 * scope "<guide source id>\u0001<xmltv id>", so every existing reader keeps working. An import that keeps no programmes never replaces a working guide; its diagnostics say why.
 * Locked, hidden, adult and kids channels are never matched and never enriched.
 */
class GuideHubService(
    private val db: AppDatabase, private val credentials: CredentialStore, private val epg: EpgService, private val dir: File,
    private val prefs: android.content.SharedPreferences, private val clock: () -> Long = { System.currentTimeMillis() },
) {
    private val mutex = Mutex()
    private val dao get() = db.guideHub()

    var enrichmentEnabled: Boolean
        get() = prefs.getBoolean(KEY_ENRICH, true)
        set(v) { prefs.edit().putBoolean(KEY_ENRICH, v).apply() }

    data class TestReport(val valid: Boolean, val channels: Int = 0, val programmes: Int = 0, val message: String)

    fun parseAddress(raw: String): String? = raw.trim().takeIf { it.startsWith("https://") || it.startsWith("http://") }?.takeIf { java.net.URI.create(it.replace(" ", "%20")).host?.isNotEmpty() == true }

    // ---- sources

    suspend fun addSource(name: String, address: String): String {
        val url = parseAddress(address) ?: throw IllegalArgumentException("Enter a web address that starts with https:// (or http://).")
        val id = "user:" + UUID.randomUUID().toString().lowercase()
        credentials.save("guide.$id", url)
        dao.putSource(GuideSourceEntity(id, "userXMLTV", name.ifBlank { java.net.URI.create(url).host ?: "Guide" }, urlRef = "guide.$id", createdAt = clock()))
        return id
    }
    suspend fun removeSource(id: String) {
        credentials.delete("guide.$id")
        dao.deleteProgrammesOf(id); dao.deleteGuideChannelsOf(id); dao.clearAllOf(id); dao.deleteDiagnostic(id); dao.deleteSource(id)
        epg.guideChanged()
    }
    suspend fun setEnabled(id: String, on: Boolean) { dao.setEnabled(id, on); epg.guideChanged() }

    /** Reads the first part of the address and says what it is. Never lists channel names. */
    suspend fun test(address: String): TestReport = withContext(Dispatchers.IO) {
        val url = parseAddress(address) ?: return@withContext TestReport(false, message = "Enter a web address that starts with https:// (or http://).")
        try {
            var stats = GuideReadStats()
            Http.get(url) { resp -> stats = decode(resp.body!!.byteStream(), clock() - 3600_000, clock() + 7 * 86400_000L, null, { }, { }) }
            TestReport(true, stats.channels, stats.programmesKept, if (stats.programmesKept == 0) "A valid guide, but it holds no programmes." else "Valid guide: ${stats.channels} channels, ${stats.programmesKept} programmes.")
        } catch (e: Exception) { TestReport(false, message = redact(e.message ?: "The guide could not be read.")) }
    }

    // ---- refresh

    data class Outcome(val id: String, val outcome: String, val kept: Int, val error: String?)

    /** Imports every enabled added guide that is due (or all, when [force]), then maps channels to them, then enriches when that is switched on. One run at a time. */
    suspend fun refresh(force: Boolean, windowDays: Int = 3): List<Outcome> = mutex.withLock {
        val results = ArrayList<Outcome>()
        for (s in dao.sources().filter { it.enabled && it.kind == "userXMLTV" }) {
            val last = dao.diagnostic(s.id)
            val hours = maxOf(s.refreshHours, 1)
            val due = force || last == null || clock() - (last.lastSuccess ?: last.lastAttempt) >= hours * 3600_000L && (last.outcome != "failed" || clock() - last.lastAttempt >= backoffMs(last))
            if (!due) continue
            val r = importSource(s, windowDays)
            results.add(r)
            if (r.outcome == "ok") { mapSource(s.id); epg.guideChanged() }
        }
        if (enrichmentEnabled) runCatching { enrich(force) }
        results
    }

    private fun backoffMs(d: GuideDiagnosticsEntity): Long = 600_000L      // ten minutes after a failure, then the normal interval

    private fun redact(s: String): String = s.replace(Regex("(?i)(token|key|password|user|pass)=[^&\\s]+"), "$1=…").replace(Regex("https?://\\S+"), "the guide address")

    private fun decode(input: java.io.InputStream, from: Long, to: Long, zone: String?, onChannel: (GuideChannelRecord) -> Unit, onProgramme: (GuideProgramme) -> Unit): GuideReadStats {
        val raw = java.io.BufferedInputStream(input)
        raw.mark(2); val b0 = raw.read(); val b1 = raw.read(); raw.reset()
        val gz = b0 == 0x1f && b1 == 0x8b
        val counted = EpgService.GuideLimits.CountingStream(raw)
        val guarded = EpgService.GuideLimits.Guard(if (gz) GZIPInputStream(counted) else counted, counted, gz, clock())
        return XmltvDecoder.read(guarded, from, to, zone, onChannel, onProgramme)
    }

    private suspend fun importSource(s: GuideSourceEntity, windowDays: Int): Outcome = withContext(Dispatchers.IO) {
        val now = clock()
        val url = s.urlRef?.let { credentials.load(it) }
        if (url == null) { record(s.id, now, "failed", error = "The address of this guide is no longer stored. Add it again."); return@withContext Outcome(s.id, "failed", 0, "address missing") }
        val from = now - 3 * 3600_000L; val to = now + windowDays * 86400_000L
        val batch = ArrayList<EpgEntity>(1000); val names = ArrayList<EpgChannelEntity>()
        var written = 0
        val tmp = ArrayList<EpgEntity>()
        try {
            var stats = GuideReadStats(); var etag: String? = null; var lastMod: String? = null
            val headers = HashMap<String, String>().also { h -> s.etag?.let { h["If-None-Match"] = it }; s.lastModified?.let { h["If-Modified-Since"] = it } }
            try {
                Http.get(url, null, headers) { resp ->
                    etag = resp.header("ETag"); lastMod = resp.header("Last-Modified")
                    stats = decode(resp.body!!.byteStream(), from, to, if (s.tzMode == "local") s.tzZone else null,
                        { c -> if (names.size < XmltvDecoder.MAX_CHANNELS) c.displayNames.firstOrNull()?.let { n -> names.add(EpgChannelEntity(EpgIds.scope(s.id, c.id), app.streamsetu.core.data.repo.SearchText.normalize(n))) } },
                        { p -> tmp.add(EpgEntity(EpgIds.scope(s.id, p.channel), p.startMs, p.stopMs, p.title, p.description)) })
                }
            } catch (e: HttpStatusException) {
                if (e.code == 304) { record(s.id, now, "notModified", httpStatus = 304); return@withContext Outcome(s.id, "notModified", 0, null) }
                throw e
            }
            if (stats.programmesKept == 0) {
                val msg = if (stats.programmesSeen == 0) "The guide contained no programmes." else "The guide contained no programmes for the days kept."
                record(s.id, now, "empty", stats = stats, error = msg)
                return@withContext Outcome(s.id, "empty", 0, msg)
            }
            tmp.chunked(1000).forEach { db.epg().put(it) }; written = tmp.size
            names.chunked(1000).forEach { db.extras().putEpgChannels(it) }
            dao.pruneProgrammesOf(s.id, now - 3600_000L)
            dao.setValidators(s.id, etag, lastMod)
            record(s.id, now, "ok", stats = stats)
            Outcome(s.id, "ok", written, null)
        } catch (e: kotlinx.coroutines.CancellationException) { throw e }
        catch (e: Exception) { val m = redact(e.message ?: "The guide could not be read."); record(s.id, now, "failed", error = m); Outcome(s.id, "failed", 0, m) }
    }

    private suspend fun record(id: String, now: Long, outcome: String, stats: GuideReadStats = GuideReadStats(), httpStatus: Int? = null, error: String? = null) {
        val old = dao.diagnostic(id)
        val ok = outcome == "ok" || outcome == "notModified"
        val keep = outcome == "notModified" && old != null
        dao.putDiagnostic(GuideDiagnosticsEntity(
            id, now, if (ok) now else old?.lastSuccess, outcome, httpStatus, null,
            if (keep) old!!.channels else stats.channels, old?.mapped ?: 0, if (keep) old!!.programmesSeen else stats.programmesSeen, if (keep) old!!.programmesKept else stats.programmesKept,
            if (keep) old!!.droppedPast else stats.droppedPast, if (keep) old!!.droppedFuture else stats.droppedFuture, if (keep) old!!.droppedInvalid else stats.droppedInvalid,
            if (keep) old!!.fileFirstStart else stats.firstStartMs, if (keep) old!!.fileLastStop else stats.lastStopMs, stats.truncated, error?.let(::redact), dao.lastEndOf(id)))
    }

    /** Called by the provider refresh so the playlist's own guide has the same diagnostics (what the last read found, or why it failed). */
    suspend fun recordProviderRead(sourceId: String, name: String, kept: Int, error: String?) {
        val id = "provider:$sourceId"
        if (dao.source(id) == null) dao.putSource(GuideSourceEntity(id, "provider", name, priority = 10, createdAt = clock()))
        val now = clock()
        record(id, now, if (error != null) "failed" else if (kept == 0) "empty" else "ok", stats = GuideReadStats(programmesSeen = kept, programmesKept = kept), error = error)
    }

    // ---- mapping

    private fun restrictedWords(name: String?, category: String?): Boolean {
        val t = ((name ?: "") + " " + (category ?: "")).lowercase()
        return listOf("adult", "xxx", "18+", "porn", "erotic", "kids", "children", "junior").any { it in t }
    }

    suspend fun restrictedIds(): Set<String> = dao.channelRows().filter { it.restricted || restrictedWords(it.name, it.categoryName) }.map { it.id }.toSet()

    /** Matches the library to one added guide. Manual choices are kept; restricted channels are skipped. */
    suspend fun mapSource(guideSourceId: String): Int {
        val rows = dao.channelRows()
        val locks = dao.userMappings().associateBy { it.channelId }
        val guide = dao.guideChannelsOf(guideSourceId).map { MapGuideChannel(guideSourceId, EpgIds.raw(it.epgId), listOf(it.nameNorm), priority = 20) }
        val input = rows.map { r -> MapChannel(r.id, r.name, r.epgId, null, null, null, null, emptyList(), r.restricted || restrictedWords(r.name, r.categoryName),
            locks[r.id]?.takeIf { it.guideSourceId == guideSourceId }?.let { GuideMatch(guideSourceId, it.xmltvId, "user", 1.0, "chosen by you") }) }
        val results = GuideMappingEngine.map(input, guide)
        val now = clock()
        val matches = results.mapNotNull { r -> r.match?.takeIf { it.method != "user" }?.let { ChannelGuideMapEntity(r.channelId, guideSourceId, it.xmltvId, it.method, it.confidence, it.reason, false, now) } }
        dao.clearAutomatic(guideSourceId); dao.putMappings(matches)
        dao.diagnostic(guideSourceId)?.let { dao.putDiagnostic(it.copy(mapped = dao.mappedCount(guideSourceId))) }
        return matches.size
    }

    /** A manual choice: stored locked, never recomputed. [xmltvId] null removes it. */
    suspend fun setUserMapping(channelId: String, guideSourceId: String?, xmltvId: String?) {
        dao.clearUser(channelId)
        if (guideSourceId != null && xmltvId != null) dao.putMappings(listOf(ChannelGuideMapEntity(channelId, guideSourceId, xmltvId, "user", 1.0, "chosen by you", true, clock())))
        epg.guideChanged()
    }

    /** Channels of the added guides, for the manual match screen. */
    suspend fun addedGuideChannels(): List<Triple<String, String, String>> {
        val ids = dao.sources().filter { it.enabled && it.kind == "userXMLTV" }.map { it.id }
        return ids.flatMap { sid -> dao.guideChannelsOf(sid).map { Triple(sid, EpgIds.raw(it.epgId), it.nameNorm) } }
    }

    // ---- status

    suspend fun statuses(): List<GuideSourceStatus> {
        val now = clock()
        runCatching { ensureProviderRows() }
        val diags = dao.diagnostics().associateBy { it.guideSourceId }
        val scopes = db.epg().guideStamps().associateBy { it.scope }
        return dao.sources().map { s ->
            val d = diags[s.id]
            val scopeKey = if (s.kind == "provider") s.id.removePrefix("provider:") else s.id
            val n = scopes[scopeKey]?.n ?: 0; val end = scopes[scopeKey]?.lastEnd
            val f = GuideDiagnosisAdvisor.freshness(d, s.enabled, n, end, s.refreshHours, now)
            val fd = GuideDiagnosisAdvisor.findings(d ?: if (s.kind == "provider" && n == 0) null else d, f, now)
            GuideSourceStatus(s.id, s.name, s.kind, s.enabled, f, GuideMessages.render(f.key, *listOfNotNull(f.amount).toTypedArray()), fd, n, d?.mapped ?: dao.mappedCount(s.id))
        }
    }

    private suspend fun ensureProviderRows() {
        for (p in dao.enabledSourceNames()) { val id = "provider:${p.id}"; if (dao.source(id) == null) dao.putSource(GuideSourceEntity(id, "provider", p.name, priority = 10, createdAt = clock())) }
    }

    // ---- public channel database

    private val iptv by lazy { IptvOrgStore(File(dir, "iptvorg"), clock) }

    suspend fun enrich(force: Boolean = false): Int = withContext(Dispatchers.IO) {
        val index = iptv.index(force) ?: return@withContext 0
        val restricted = restrictedIds()
        val rows = dao.channelRows()
        val now = clock()
        val out = ArrayList<ChannelEnrichmentEntity>()
        for (r in rows) {
            if (r.id in restricted || restrictedWords(r.name, r.categoryName)) { dao.deleteEnrichment(r.id); continue }
            val m = IptvOrgEnricher.match(r.name, r.epgId, null, false, index)
            if (m == null) { dao.deleteEnrichment(r.id); continue }
            out.add(ChannelEnrichmentEntity(r.id, m.dbId, m.logoUrl, GuideCategoryMapper.genre(m.categories), m.country?.lowercase(), m.languages.firstOrNull(), m.matchedBy, m.confidence, now))
        }
        out.chunked(500).forEach { dao.putEnrichment(it) }
        publishOverlay(out, rows)
        out.size
    }

    private fun publishOverlay(e: List<ChannelEnrichmentEntity>, rows: List<GuideChannelRow>) {
        val byId = rows.associateBy { it.id }
        // Only a channel that has no logo of its own gains one; the picture code looks the name up (it is not handed the channel id).
        GuideOverlay.set(e.filter { it.logoUrl != null && byId[it.channelId]?.logoUrl.isNullOrBlank() }.mapNotNull { x -> byId[x.channelId]?.let { ChannelNormalizer.name(it.name).key to x.logoUrl!! } }.toMap())
    }

    suspend fun undoEnrichment() { dao.clearEnrichment(); GuideOverlay.set(emptyMap()) }

    suspend fun loadOverlay() { publishOverlay(dao.enrichment(), dao.channelRows()) }

    companion object { const val KEY_ENRICH = "guidehub.enrichment.enabled" }
}

/** Logo addresses from the public database by channel id, read by the picture code for a channel that has no logo of its own. Memory only. */
object GuideOverlay {
    @Volatile private var byName: Map<String, String> = emptyMap()
    fun set(m: Map<String, String>) { byName = m }
    fun logoForName(name: String): String? = if (byName.isEmpty()) null else byName[ChannelNormalizer.name(name).key]
}

object GuideCategoryMapper {
    private val map = mapOf(
        "general" to "general", "news" to "news", "sports" to "sports", "entertainment" to "entertainment", "movies" to "movies", "classic" to "movies", "series" to "series", "kids" to "kids",
        "animation" to "kids", "family" to "kids", "music" to "music", "comedy" to "entertainment", "documentary" to "factual", "science" to "factual", "education" to "factual", "culture" to "factual",
        "travel" to "factual", "outdoor" to "factual", "auto" to "factual", "cooking" to "factual", "lifestyle" to "factual", "relax" to "factual", "religious" to "religious", "business" to "news",
        "legislative" to "news", "public" to "news", "weather" to "news", "shop" to "shopping", "interactive" to "other",
    )
    fun genre(categories: List<String>): String? { for (c in categories) if (c != "xxx") map[c]?.let { return it }; return null }
}

/** Downloads and caches the static public database files: at most once a day each, conditional (ETag), and the block list is mandatory (missing, unreadable or older than 30 days: no index). */
class IptvOrgStore(private val dir: File, private val clock: () -> Long) {
    private val base = "https://iptv-org.github.io/api/"
    private val files = listOf("blocklist", "channels", "feeds", "logos")
    private val failures = HashMap<String, Int>()
    private var openUntil = 0L

    private fun meta(f: String) = File(dir, "$f.meta")
    private fun readMeta(f: String): Triple<Long, String?, String?>? = runCatching { meta(f).readLines().let { Triple(it[0].toLong(), it.getOrNull(1)?.ifEmpty { null }, it.getOrNull(2)?.ifEmpty { null }) } }.getOrNull()

    fun refresh(force: Boolean) {
        dir.mkdirs()
        for (f in files) {
            val m = readMeta(f); val now = clock()
            if (!force && m != null && now - m.first < 24 * 3600_000L && File(dir, "$f.json").exists()) continue
            if (now < openUntil) { if (f == "blocklist") return else continue }           // circuit breaker: five failures, fifteen minutes
            val h = HashMap<String, String>().also { x -> m?.second?.let { x["If-None-Match"] = it }; m?.third?.let { x["If-Modified-Since"] = it } }
            try {
                var etag: String? = null; var lm: String? = null
                val tmp = File(dir, "$f.tmp")
                Http.get(base + "$f.json", null, h) { resp ->
                    etag = resp.header("ETag"); lm = resp.header("Last-Modified")
                    tmp.outputStream().use { out -> resp.body!!.byteStream().copyTo(out) }
                }
                val head = tmp.inputStream().use { it.read().let { _ -> tmp.readText(Charsets.UTF_8).trimStart().firstOrNull() } }
                if (head != '[') { tmp.delete(); error("not a list") }
                tmp.renameTo(File(dir, "$f.json")); meta(f).writeText("$now\n${etag ?: ""}\n${lm ?: ""}")
                failures.remove(f)
            } catch (e: HttpStatusException) {
                if (e.code == 304) { meta(f).writeText("$now\n${m?.second ?: ""}\n${m?.third ?: ""}"); continue }
                fail(f, now); if (f == "blocklist") return
            } catch (e: Exception) { fail(f, now); if (f == "blocklist") return }
        }
    }
    private fun fail(f: String, now: Long) { failures[f] = (failures[f] ?: 0) + 1; if (failures.values.sum() >= 5) openUntil = now + 15 * 60_000L }

    /** Null when the block list is not available: nothing is matched then. */
    fun index(force: Boolean): IptvOrgIndex? {
        refresh(force)
        val bm = readMeta("blocklist") ?: return null
        if (clock() - bm.first > 30 * 24 * 3600_000L) return null
        return try {
            fun txt(n: String) = File(dir, "$n.json").takeIf { it.exists() }?.readText()
            IptvOrgIndex.build(IptvOrgIndex.parseChannels(txt("channels") ?: return null), txt("blocklist"), txt("logos")?.let { runCatching { IptvOrgIndex.parseLogos(it) }.getOrNull() }.orEmpty(),
                txt("feeds")?.let { runCatching { IptvOrgIndex.parseFeeds(it) }.getOrNull() }.orEmpty())
        } catch (e: BlocklistUnavailable) { null } catch (e: Exception) { null }
    }
}

/** Records what a playlist's own guide read found, from code that has only the database (the provider refresh). */
object GuideHubRecorder {
    suspend fun providerRead(db: AppDatabase, sourceId: String, name: String, kept: Int, error: String?, now: Long = System.currentTimeMillis()) {
        val dao = db.guideHub(); val id = "provider:$sourceId"
        if (dao.source(id) == null) dao.putSource(GuideSourceEntity(id, "provider", name, priority = 10, createdAt = now))
        val old = dao.diagnostic(id)
        val outcome = if (error != null) "failed" else if (kept == 0) "empty" else "ok"
        val ok = outcome == "ok"
        dao.putDiagnostic(GuideDiagnosticsEntity(id, now, if (ok) now else old?.lastSuccess, outcome, programmesSeen = kept, programmesKept = kept, error = error?.take(200), windowEnd = dao.lastEndOf(sourceId)))
    }
}
