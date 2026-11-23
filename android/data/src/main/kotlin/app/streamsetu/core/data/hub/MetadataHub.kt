package app.streamsetu.core.data.hub

import app.streamsetu.core.data.db.HubDao
import app.streamsetu.core.data.db.HubIdentityEntity
import app.streamsetu.core.data.db.MetadataFactEntity
import app.streamsetu.core.net.Http
import app.streamsetu.core.net.HttpStatusException
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/** Runs one request and returns the body. Errors: [HttpStatusException] for a refusal, IOException for no answer. */
fun interface HubFetch { fun run(req: HubRequest): String }

/** The ordinary way: the app's shared client (its proxy and DNS rules apply). Keys travel only in headers or the JSON body. A reply is read to at most [MAX_BYTES]. These are not TMDB requests (those all go through the app's one TMDB pacer). */
object HubHttp : HubFetch {
    const val MAX_BYTES = 2_000_000L
    override fun run(req: HubRequest): String {
        val b = Request.Builder().url(req.url).apply { req.headers.forEach { (k, v) -> header(k, v) } }
        if (req.method == "POST") b.post((req.body ?: "").toRequestBody("application/json".toMediaType()))
        Http.client.newCall(b.build()).execute().use { r ->
            if (!r.isSuccessful) throw HttpStatusException(r.code, r.header("Retry-After")?.trim()?.toLongOrNull())
            val src = r.body?.source() ?: return ""
            src.request(MAX_BYTES + 1)
            if (src.buffer.size > MAX_BYTES) throw java.io.IOException("The answer is larger than this app reads.")
            return src.buffer.readUtf8()
        }
    }
}

/** TheTVDB login and token: the 30-day token is kept in memory and in the secret store (Keystore-backed on device), only ever sent in an Authorization header. */
class TVDBSession(private val access: HubAccess, private val secrets: HubSecretStore, private val fetch: HubFetch, private val now: () -> Long = System::currentTimeMillis) {
    private var token: String? = null
    private var issued = 0L
    init {
        secrets.get(HubAccess.TVDB_TOKEN_ACCOUNT)?.let { raw -> TVDBProvider.decodeToken(raw)?.let { (t, at) -> if (now() - at < TVDBProvider.TOKEN_LIFE_MS - 86_400_000) { token = t; issued = at } } }
    }
    @Synchronized fun currentToken(force: Boolean = false): String {
        token?.let { if (!force && now() - issued < TVDBProvider.TOKEN_LIFE_MS - 86_400_000) return it }
        val own = access.ownKey
        val key = own ?: access.builtInKey()?.takeIf { access.builtInUsable } ?: throw HttpStatusException(401)
        try {
            val t = TVDBProvider.parseToken(fetch.run(TVDBProvider.loginRequest(key, if (own != null) access.pin else null))) ?: throw java.io.IOException("unreadable")
            token = t; issued = now(); secrets.set(HubAccess.TVDB_TOKEN_ACCOUNT, TVDBProvider.encodeToken(t, issued))
            return t
        } catch (e: HttpStatusException) {
            if (e.code == 401 || e.code == 403) { if (own == null) access.markBuiltInRejected(); token = null; secrets.set(HubAccess.TVDB_TOKEN_ACCOUNT, null) }
            throw e
        }
    }
    fun get(path: String): String {
        return try { fetch.run(TVDBProvider.authorized(path, currentToken())) }
        catch (e: HttpStatusException) { if (e.code == 401) fetch.run(TVDBProvider.authorized(path, currentToken(force = true))) else throw e }          // an expired token: log in once more
    }
}

/** The Test button for one source: one small request, reporting only accepted, key refused, or no answer. */
object HubTester {
    const val OK = "Accepted. This source is working."
    const val REFUSED = "The key was refused. Check that you copied it whole."
    const val SLOW = "The service asked us to slow down. Try again in a few minutes."
    const val NO_ANSWER = "No answer, try again."
    fun check(source: HubSource, access: HubAccess, secrets: HubSecretStore, fetch: HubFetch): Pair<Boolean, String> {
        return try {
        when (source) {
            HubSource.FANART -> { val k = access.fanartKeys() ?: return false to "No key available."; fetch.run(FanartProvider.request(HubTitleKind.MOVIE, "603", k)) }
            HubSource.TVDB -> { if (!access.enabled && access.ownKey == null) return false to "Switched off."; TVDBSession(access, secrets, fetch).currentToken(force = true) }
            HubSource.TVMAZE -> fetch.run(HubRequest("https://api.tvmaze.com/shows/1"))
            else -> return false to NO_ANSWER
        }
        true to OK
        } catch (e: HttpStatusException) {
            false to when (e.code) { 401, 403 -> REFUSED; 429 -> SLOW; else -> NO_ANSWER }
        } catch (e: Exception) { false to NO_ANSWER }
    }
}

/** What the hub saves (Room on device). Misses are rows with no value and a missUntil. */
interface HubFactStore {
    suspend fun fact(item: String, field: String): Pair<StoredFact, Long?>?
    suspend fun put(item: String, field: String, value: String, source: HubSource, quality: Double, now: Long, keepMs: Long): Boolean
    suspend fun putMiss(item: String, field: String, source: HubSource, until: Long, now: Long)
    suspend fun saveIdentity(item: String, incoming: HubIdentity, from: HubSource, now: Long)
    suspend fun identity(item: String): HubIdentity?
    suspend fun provenance(item: String): Set<HubSource>
}

class RoomHubStore(private val dao: HubDao) : HubFactStore {
    override suspend fun fact(item: String, field: String): Pair<StoredFact, Long?>? = dao.fact(item, field)?.let {
        StoredFact(it.value.orEmpty(), HubSource.of(it.source) ?: HubSource.PLAYLIST, it.quality, it.expiresAt, it.failCount) to it.missUntil }
    override suspend fun put(item: String, field: String, value: String, source: HubSource, quality: Double, now: Long, keepMs: Long): Boolean {
        val s = fact(item, field)?.first
        if (s != null && s.value.isNotEmpty()) {
            if (s.quality.isInfinite()) return false
            val expired = s.expiresAt <= now || s.failCount >= Arbiter.MAX_FAILURES
            if (!expired && quality <= s.quality + Arbiter.MARGIN && value != s.value) return false
        }
        dao.putFact(MetadataFactEntity(item, field, value, source.key, if (quality.isInfinite()) 1e12 else quality, now, now + keepMs))
        return true
    }
    override suspend fun putMiss(item: String, field: String, source: HubSource, until: Long, now: Long) { dao.putFact(MetadataFactEntity(item, field, null, source.key, 0.0, now, until, until)) }
    override suspend fun identity(item: String): HubIdentity? = dao.identity(item)?.let { HubIdentity(it.tmdbId, it.tvdbId, it.imdbId, it.tvmazeId, it.kind?.let { k -> HubTitleKind.entries.firstOrNull { e -> e.key == k } }) }
    override suspend fun saveIdentity(item: String, incoming: HubIdentity, from: HubSource, now: Long) {
        val merged = HubIdentity.merge(identity(item) ?: HubIdentity(), incoming, HubIdentity.rank(from), if (from == HubSource.PLAYLIST) 99 else 0)
        dao.putIdentity(HubIdentityEntity(item, merged.tmdb, merged.tvdb, merged.imdb, merged.tvmaze, merged.kind?.key, now))
    }
    override suspend fun provenance(item: String): Set<HubSource> = dao.provenance(item).mapNotNull { HubSource.of(it) }.toSet()
}

/**
 * The one thing services call for extra artwork and next-episode data. fanart.tv rules (its terms): express lane only, one request per title until expiry (plus negative caching), a low
 * global rate and a daily cap, no crawling. Locked or hidden titles are never requested ([isSendable]). Offline-capable: reads come from the saved facts.
 */
class MetadataHub(
    private val store: HubFactStore, private val access: Map<HubSource, HubAccess>, private val fetch: HubFetch,
    private val tvdb: TVDBSession? = null, private val isSendable: suspend (String) -> Boolean = { true },
    private val ctx: ArtContext = ArtContext(), private val now: () -> Long = System::currentTimeMillis,
) {
    private val buckets = HashMap<HubSource, TokenBucket>(); private val breakers = HashMap<HubSource, CircuitBreaker>(); private val queues = HashMap<HubSource, HubQueue>()
    data class Result(val asked: List<HubSource>, val stored: List<String>, val skipped: Map<HubSource, String>)

    /** An item id each time something new was saved for it, so an open title page reads again. */
    private val _landed = kotlinx.coroutines.flow.MutableSharedFlow<String>(extraBufferCapacity = 16, onBufferOverflow = kotlinx.coroutines.channels.BufferOverflow.DROP_OLDEST)
    val landed: kotlinx.coroutines.flow.SharedFlow<String> = _landed

    suspend fun image(item: String, kind: ArtKind, season: Int? = null): String? = store.fact(item, field(kind, season))?.first?.value?.takeIf { it.isNotEmpty() }
    suspend fun text(item: String, field: String): String? = store.fact(item, field)?.first?.value?.takeIf { it.isNotEmpty() }
    suspend fun provenance(item: String): Set<HubSource> = store.provenance(item)
    suspend fun attributionFooter(item: String): String? = HubAttribution.footer(store.provenance(item))
    fun field(k: ArtKind, season: Int? = null) = if (k == ArtKind.SEASON_POSTER) "seasonposter:${season ?: 0}" else k.key

    /** A title was opened or is on screen (the caller debounces a quick scroll). Requests are blocking, so they run on the IO dispatcher. */
    suspend fun refresh(item: String, identity: HubIdentity, kind: HubTitleKind): Result = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { refreshNow(item, identity, kind) }.also { if (it.stored.isNotEmpty()) _landed.tryEmit(item) }

    private suspend fun refreshNow(item: String, identity: HubIdentity, kind: HubTitleKind): Result {
        val asked = mutableListOf<HubSource>(); val stored = mutableListOf<String>(); val skipped = HashMap<HubSource, String>()
        if (!isSendable(item)) return Result(asked, stored, skipped)
        val t = now()
        val missing = listOf(ArtKind.LOGO, ArtKind.BACKDROP, ArtKind.POSTER).filter { !Arbiter.atTarget(it, store.fact(item, field(it))?.first, t) }
        if (missing.isNotEmpty()) for (source in listOf(HubSource.FANART, HubSource.TVDB)) {
            val why = gate(source, item, "art:${source.key}", identity, kind)
            if (why != null) { skipped[source] = why; continue }
            asked += source
            try {
                val text = when (source) {
                    HubSource.FANART -> { val req = FanartProvider.request(kind, identity.queryId(source, kind)!!, access[source]!!.fanartKeys()!!); fetch.run(req) }
                    else -> tvdb!!.get(if (kind == HubTitleKind.SERIES) "/series/${identity.tvdb}/artworks" else "/movies/${identity.tvdb}/extended")
                }
                val cands = if (source == HubSource.FANART) FanartProvider.parse(text, kind) else TVDBProvider.parseArtworks(text, kind)
                breakers.getOrPut(source) { CircuitBreaker() }.success()
                var any = false
                for (k in missing) Arbiter.pick(k, cands, ctx)?.let { p -> if (store.put(item, field(k), p.candidate.url, source, p.score, t, HubPolicy.of(source).keepMs)) { stored += field(k); any = true } }
                val keep = HubPolicy.of(source).keepMs
                store.putMiss(item, "art:${source.key}", source, t + if (any || cands.isNotEmpty()) keep else NegativeCache.NOT_FOUND_MS, t)           // one request per title until expiry
            } catch (e: Exception) { handle(e, source, item, "art:${source.key}", t) }
        }
        if (kind == HubTitleKind.SERIES && gate(HubSource.TVMAZE, item, "episodes", identity, kind) == null) {
            asked += HubSource.TVMAZE
            try {
                var req = TVmazeProvider.showRequest(identity)!!
                var show = TVmazeProvider.parseShow(fetch.run(req))
                if (identity.tvmaze == null && show != null) show = TVmazeProvider.parseShow(fetch.run(TVmazeProvider.showRequest(HubIdentity(tvmaze = show.ids.tvmaze))!!)) ?: show        // the lookup redirects: one more call for the embedded data
                breakers.getOrPut(HubSource.TVMAZE) { CircuitBreaker() }.success()
                if (show != null) {
                    store.saveIdentity(item, show.ids, HubSource.TVMAZE, t)
                    show.next?.airstamp?.let { if (store.put(item, "nextepisode", it, HubSource.TVMAZE, 100.0, t, HubPolicy.TVMAZE.keepMs)) stored += "nextepisode" }
                    store.putMiss(item, "episodes", HubSource.TVMAZE, t + 7 * 86_400_000L, t)
                } else store.putMiss(item, "episodes", HubSource.TVMAZE, t + NegativeCache.NOT_FOUND_MS, t)
            } catch (e: Exception) { handle(e, HubSource.TVMAZE, item, "episodes", t) }
        }
        return Result(asked, stored, skipped)
    }

    private suspend fun gate(source: HubSource, item: String, field: String, identity: HubIdentity, kind: HubTitleKind): String? {
        val t = now(); val a = access[source]
        if (a == null || a.origin == HubAccess.Origin.NONE) return "off"
        if (source == HubSource.FANART && a.fanartKeys() == null) return "no key"
        if (source == HubSource.TVDB && tvdb == null) return "off"
        if (identity.queryId(source, kind) == null) return "no id"
        store.fact(item, field)?.second?.let { if (it > t) return "remembered" }
        if (!breakers.getOrPut(source) { CircuitBreaker() }.allow(t)) return "breaker open"
        val q = queues.getOrPut(source) { HubQueue(HubPolicy.of(source), t) }
        q.enqueue("$item#$field", HubLane.EXPRESS)
        val n = q.next(t) ?: return "daily cap"
        q.finish(n.first)
        if (buckets.getOrPut(source) { TokenBucket(HubPolicy.of(source), t) }.take(t) > 0) return "rate"
        return null
    }

    private suspend fun handle(e: Exception, source: HubSource, item: String, field: String, t: Long) {
        var outcome: NegativeCache.Outcome = NegativeCache.Outcome.Offline
        if (e is HttpStatusException) {
            outcome = NegativeCache.outcome(e.code, e.retryAfterSeconds?.toDouble())
            if ((e.code == 401 || e.code == 403) && access[source]?.ownKey == null) access[source]?.markBuiltInRejected()
        }
        if (outcome == NegativeCache.Outcome.Offline) return                         // offline just waits
        breakers.getOrPut(source) { CircuitBreaker() }.failure(t)
        NegativeCache.missUntil(outcome, t)?.let { store.putMiss(item, field, source, it, t) }
    }
}
