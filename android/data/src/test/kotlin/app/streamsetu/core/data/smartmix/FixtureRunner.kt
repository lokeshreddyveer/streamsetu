package app.streamsetu.core.data.smartmix

import kotlinx.serialization.json.*
import java.io.File

/** Loads a shared fixture and replays its steps through the production [SmartMixService] path (no test-only ranking code). */
object FixtureRunner {
    class StepOut(val ids: Map<String, List<String>>, val art: Map<String, List<String>>, val diag: Map<String, ShelfDiagnostics>)

    private fun JsonElement?.str(): String? = if (this == null || this is JsonNull) null else jsonPrimitive.content
    private fun JsonElement?.int(): Int? = if (this == null || this is JsonNull) null else jsonPrimitive.int
    private fun JsonElement?.bool(def: Boolean = false): Boolean = if (this == null || this is JsonNull) def else jsonPrimitive.boolean

    fun toCandidate(o: JsonObject): Candidate = Candidate(
        id = o["id"].str()!!, kind = if (o["kind"].str() == "series") Kind.SERIES else Kind.MOVIE, identityKey = o["key"].str() ?: "",
        year = o["year"].int(), addedDays = o["added"].int(), ratingText = o["rating"].str(), qualityRank = o["q"].int() ?: 2, isCam = o["cam"].bool(),
        lang = o["lang"].str(), folderKey = o["folder"].str(), franchiseKey = o["franchise"].str(), primaryGenre = o["genre"].str(),
        hasPoster = o["poster"].bool(true), hasBackdrop = o["backdrop"].bool(), watched = o["watched"].bool(), completed = o["completed"].bool(),
        lastWatchedDays = o["lastWatched"].int(), plays7 = o["p7"].int() ?: 0, plays30 = o["p30"].int() ?: 0, trendingRank = null,
        loadsAgo = null, restricted = o["restricted"].bool(), dismissed = o["dismissed"].bool(), sourceRank = o["src"].int() ?: 0,
    )

    fun applyPatch(c: Candidate, p: JsonObject): Candidate {
        var x = c
        for ((k, v) in p) x = when (k) {
            "poster" -> x.copy(hasPoster = v.bool()); "backdrop" -> x.copy(hasBackdrop = v.bool()); "restricted" -> x.copy(restricted = v.bool())
            "dismissed" -> x.copy(dismissed = v.bool()); "key" -> x.copy(identityKey = v.str()!!); "watched" -> x.copy(watched = v.bool())
            else -> error("unhandled patch field $k")
        }
        return x
    }

    // ---- the documented synthetic generator (integer only; mirrors tools/smartmix_ref.py)
    private val LANGS = listOf("Telugu", "Hindi", "English", "Tamil", "Malayalam", "Kannada")
    private val GENRES = listOf("action", "drama", "comedy", "thriller", "family", "horror", "romance", "scifi")
    fun generate(name: String, seed: Long, n: Int, folders: Int): List<Candidate> {
        val g = SplitMix64(Fnv1a64.hash("smartmix-gen1|$name|$seed"))
        fun u(k: Int) = g.uniform(k.toULong()).toInt()
        val out = ArrayList<Candidate>(n)
        for (i in 0 until n) {
            val series = u(100) < 27
            val id = (if (series) "s" else "m") + i
            val key = "t" + u(maxOf(1, n * 4 / 5))
            val year = 2026 - minOf(u(36), u(36))
            val added = if (u(100) < 5) null else u(700)
            val r0 = u(20)
            val rating = when (r0) { 0 -> ""; 1 -> "0"; 2 -> "10"; 3 -> "10.0"; else -> { val t = 30 + u(60); "${t / 10}.${t % 10}" } }
            val r = u(100)
            var q: Int; var cam = false
            if (r < 8) { q = 0; cam = true } else if (r < 15) q = 1 else if (r < 45) q = 2 else if (r < 75) q = 3 else if (r < 92) q = 4 else q = 5
            val a = u(6); val b = u(6); val lang0 = LANGS[minOf(a, b)]
            val lang = if (u(100) < 3) null else lang0
            val fa = u(folders); val fb = u(folders); val folder = "f" + (fa * fb) / folders
            val franchise = if (u(100) < 20) "fr" + u(n / 50 + 1) else null
            val gi = u(8); val genre = if (u(100) < 5) null else GENRES[gi]
            val poster = u(100) >= 12
            val backdrop = u(100) < 55
            val watched = u(100) < 6
            val completed = watched && u(100) < 70
            val lw = u(120)
            val p7 = if (u(100) < 4) 1 + u(5) else 0
            val p30 = p7 + (if (u(100) < 8) u(8) else 0)
            val restricted = u(1000) < 8
            val dismissed = u(1000) < 3
            val src = u(2)
            out.add(Candidate(id, if (series) Kind.SERIES else Kind.MOVIE, key, year, added, rating, q, cam, lang, folder, franchise, genre, poster, backdrop,
                watched, completed, if (watched) lw else null, p7, p30, null, null, restricted, dismissed, src))
        }
        return out
    }

    fun library(doc: JsonObject): List<Candidate> {
        doc["library"]?.let { return it.jsonArray.map { e -> toCandidate(e.jsonObject) } }
        val g = doc["generator"]!!.jsonObject
        return generate(g["name"].str()!!, g["seed"]!!.jsonPrimitive.long, g["n"].int()!!, g["folders"].int()!!)
    }

    fun affinity(o: JsonObject?): Affinity = if (o == null) Affinity.NONE else Affinity(
        o["topLangs"]?.jsonArray?.map { it.jsonPrimitive.content } ?: emptyList(), o["topFolders"]?.jsonArray?.map { it.jsonPrimitive.content } ?: emptyList(),
        o["topGenres"]?.jsonArray?.map { it.jsonPrimitive.content } ?: emptyList(), o["topDecades"]?.jsonArray?.map { it.jsonPrimitive.int } ?: emptyList())

    fun trendingView(tm: JsonObject?, now: Long): TrendingViewSource {
        val enabled = tm?.get("enabled").bool(true); val key = tm?.get("keyPresent").bool(false)
        val cache = tm?.get("cache")?.takeIf { it !is JsonNull }?.jsonObject
        val entries = cache?.get("entries")?.jsonArray?.map {
            val e = it.jsonObject
            TrendingEntry(e["rank"].int()!!, e["type"].str()!!, e["title"].str()!!, e["orig"].str(), e["year"].int())
        }
        val days = cache?.get("fetchedDaysAgo").int()
        val v = TrendingPolicy.view(enabled, key, days, entries)
        return TrendingViewSource { v }
    }

    /** Runs all steps of a fixture document with one shared store; returns each step's output. */
    fun run(doc: JsonObject, now: Long = 1_800_000_000_000L): List<StepOut> {
        val lib = library(doc)
        val store = InMemorySmartMixStore()
        val outs = ArrayList<StepOut>()
        for (stepEl in doc["steps"]!!.jsonArray) {
            val st = stepEl.jsonObject
            var l = lib
            st["patch"]?.jsonObject?.let { p -> l = lib.map { c -> p[c.id]?.let { applyPatch(c, it.jsonObject) } ?: c } }
            val profile = st["profile"].str()!!
            val src = FakeCandidateSource(l, Signals(st["preferredLang"].str(), affinity(st["affinity"]?.jsonObject)))
            val svc = SmartMixService(src, store, trendingView(st["tmdb"]?.jsonObject, now), clock = { now }, poolCap = st["poolCap"].int())
            val counter = st["refreshCounter"].int() ?: 0
            val day = st["dayKey"].str()!!
            val ids = LinkedHashMap<String, List<String>>(); val art = HashMap<String, List<String>>(); val diag = HashMap<String, ShelfDiagnostics>()
            for (sh in st["shelves"]!!.jsonArray.map { it.jsonPrimitive.content }) {
                val s0 = store.state(profile, sh)
                store.saveState(profile, sh, s0.copy(refreshCounter = counter))
                val b = svc.build(profile, sh, day)
                ids[sh] = b.result.ids; art[sh] = b.result.art; diag[sh] = b.result.diagnostics
                if (st["commit"].bool()) svc.commitRendered(profile, b)
            }
            outs.add(StepOut(ids, art, diag))
        }
        return outs
    }
}
