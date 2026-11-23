package app.streamsetu.core.data.repo

import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.repo.smartmix.IdentityKey
import app.streamsetu.core.model.ContentKind
import app.streamsetu.core.model.Movie
import app.streamsetu.core.model.Series
import app.streamsetu.core.parse.Xtream
import app.streamsetu.core.parse.str
import kotlinx.serialization.json.*
import java.io.File
import java.security.MessageDigest

/** What the person page shows about a person (GET /3/person/{id}). */
data class PersonInfo(
    val id: Long, val name: String, val biography: String?, val photo: String?, val department: String?,
    val born: String?, val died: String?, val birthPlace: String?, val alsoKnownAs: List<String>, val photos: List<String>,
)

/** How a person took part in a credit. */
enum class CreditKind { ON_SCREEN, CAMEO, VOICE, CREW }

/** Tells real acting roles from narration, voice, cameo and guest credits (TMDB lists them all as cast, a narrator at order 23 beside leads at order 0). */
object CreditClassifier {
    /** From the cast entry's character and billing order, or the crew job (Director/Creator) for a crew credit. */
    fun classify(role: String?, order: Int?): CreditKind {
        val r = role?.lowercase()?.trim().orEmpty()
        if (r == "director" || r == "creator") return CreditKind.CREW
        if (r.contains("voice") || r.contains("narrat") || Regex("""\bdub(bed|bing)?\b""").containsMatchIn(r)) return CreditKind.VOICE
        if (r.contains("cameo") || r.contains("guest") || r.contains("special appearance") || Regex("""\b(himself|herself|themselves|self)\b""").containsMatchIn(r)) return CreditKind.CAMEO
        return CreditKind.ON_SCREEN          // a character; the billing order only matters for a title with no character at all
    }
    /** The small tag on a tile: Voice, Narrator, Cameo or Guest; null for an acting role. */
    fun tag(role: String?, order: Int?): String? {
        val r = role?.lowercase().orEmpty()
        return when (classify(role, order)) {
            CreditKind.VOICE -> if (r.contains("narrat")) "Narrator" else "Voice"
            CreditKind.CAMEO -> if (r.contains("guest")) "Guest" else "Cameo"
            else -> null
        }
    }
    /** Producer, presenter, playback singer and the like are not part of a filmography grid. */
    fun crewOnlyCharacter(role: String?): Boolean { val r = role?.lowercase().orEmpty(); return r.contains("playback") || r.contains("producer") || r.contains("presenter") }
}

/** One film or series of a person, as TMDB lists it. [role] is the character (or Director/Creator); [order] the billing order. */
data class Credit(
    val tmdbId: Long, val series: Boolean, val title: String, val original: String?, val year: Int?, val date: String?, val poster: String?,
    val rating: Double?, val popularity: Double, val overview: String?, val role: String?, val order: Int? = null,
) {
    val key get() = (if (series) "tv" else "movie") + tmdbId
    val kind get() = CreditClassifier.classify(role, order)
    val tag get() = CreditClassifier.tag(role, order)
}

data class Filmography(val person: PersonInfo?, val credits: List<Credit>)

/** Which of the library's copies stand for one credit. */
class LibraryHit(val movie: Movie?, val series: Series?, val versions: Int) {
    val id get() = movie?.id ?: series!!.id
}

enum class FilmSort(val label: String) { NEWEST("Newest"), POPULAR("Popular"), RATING("Rating") }
enum class FilmKind(val label: String) { ALL("All"), MOVIES("Movies"), SERIES("Series") }

/** A credit with what the library says about it. [hit] is null for "Not in your library". */
data class FilmTile(val credit: Credit, val hit: LibraryHit?) { val inLibrary get() = hit != null; val key get() = credit.key }

/** Sorting and filtering of the grid, in one place (tested without a screen). */
object FilmographyView {
    fun kindOk(c: Credit, k: FilmKind) = k == FilmKind.ALL || (k == FilmKind.SERIES) == c.series
    /** Voice, narration and cameo credits are grouped after the on-screen ones. */
    fun secondary(c: Credit) = c.kind == CreditKind.VOICE || c.kind == CreditKind.CAMEO
    private fun actingOk(c: Credit, actingOnly: Boolean) = !actingOnly || c.kind == CreditKind.ON_SCREEN
    fun arrange(tiles: List<FilmTile>, sort: FilmSort, kind: FilmKind, onlyLibrary: Boolean, actingOnly: Boolean = false): List<FilmTile> {
        val l = tiles.filter { kindOk(it.credit, kind) && actingOk(it.credit, actingOnly) && (!onlyLibrary || it.inLibrary) }
        val (rest, main) = l.partition { secondary(it.credit) }
        return sorted(main, sort) + sorted(rest, sort)
    }
    /** Where the grouped (voice and cameo) credits start in an arranged list, or -1 when there are none. */
    fun secondaryStart(arranged: List<FilmTile>): Int = arranged.indexOfFirst { secondary(it.credit) }
    private fun sorted(l: List<FilmTile>, sort: FilmSort): List<FilmTile> {
        return when (sort) {
            FilmSort.NEWEST -> l.sortedWith(compareByDescending<FilmTile> { it.credit.date ?: "" }.thenByDescending { it.credit.popularity })
            FilmSort.POPULAR -> l.sortedWith(compareByDescending<FilmTile> { it.credit.popularity }.thenByDescending { it.credit.date ?: "" })
            FilmSort.RATING -> l.sortedWith(compareByDescending<FilmTile> { it.credit.rating ?: -1.0 }.thenByDescending { it.credit.popularity })
        }
    }
    /** The counts the two buttons show, after the Movies/Series filter. */
    fun counts(tiles: List<FilmTile>, kind: FilmKind, actingOnly: Boolean = false): Pair<Int, Int> { val l = tiles.filter { kindOk(it.credit, kind) && actingOk(it.credit, actingOnly) }; return l.size to l.count { it.inLibrary } }
    /** The best known titles of a person, for the "Known for" line. */
    fun knownFor(credits: List<Credit>, n: Int = 4) = credits.sortedByDescending { it.popularity }.map { it.title }.distinct().take(n)
}

/**
 * A person's complete filmography from TMDB: the person (GET /3/person/{id}, with images) and their credits (GET /3/person/{id}/combined_credits), kept in files of their own (30 days
 * fresh, removed with every other TMDB file when the key is removed or the switch turned off, and by the 180-day limit). Only the person id (or an exact-name search) is ever asked: nothing about the library.
 */
class TmdbPeople(private val auth: TmdbAuth, private val dir: File, private val fetch: TmdbCall = tmdbHttp, private val now: () -> Long = System::currentTimeMillis) {
    val enabled get() = auth.available

    companion object {
        const val PREFIX = "person-"
        const val MAX_PHOTOS = 6
        private val base = "https://image.tmdb.org/t/p/"
        private fun sha(s: String) = MessageDigest.getInstance("SHA-256").digest(s.toByteArray()).take(10).joinToString("") { "%02x".format(it) }
        private fun year(d: String?) = d?.take(4)?.toIntOrNull()?.takeIf { it in 1888..2100 }

        fun parsePerson(json: String): PersonInfo? {
            val o = Xtream.parseObject(json) ?: return null
            val id = o["id"]?.jsonPrimitive?.longOrNull ?: return null
            val name = o.str("name") ?: return null
            val photos = ((o["images"] as? JsonObject)?.get("profiles") as? JsonArray).orEmpty().mapNotNull { (it as? JsonObject)?.str("file_path")?.let { p -> "${base}w185$p" } }.take(MAX_PHOTOS)
            val aka = (o["also_known_as"] as? JsonArray).orEmpty().mapNotNull { (it as? JsonPrimitive)?.contentOrNull?.takeIf(String::isNotBlank) }
            return PersonInfo(id, name, o.str("biography")?.trim(), o.str("profile_path")?.let { "${base}w342$it" }, o.str("known_for_department"), o.str("birthday"), o.str("deathday"), o.str("place_of_birth"), aka, photos)
        }

        /** Cast credits, plus Director/Creator crew credits for a person known for directing or writing; de-duplicated; a credit with neither a date nor a poster dropped; talk shows and news out. */
        fun parseCredits(json: String, department: String? = null): List<Credit> {
            val o = Xtream.parseObject(json) ?: return emptyList()
            val cast = (o["cast"] as? JsonArray).orEmpty()
            val crew = (o["crew"] as? JsonArray).orEmpty()
            val wantCrew = department != null && department != "Acting" || cast.isEmpty()
            val out = LinkedHashMap<String, Credit>()
            fun add(e: JsonElement, role: String?) {
                val c = e as? JsonObject ?: return
                if (CreditClassifier.crewOnlyCharacter(role)) return
                val series = when (c.str("media_type")) { "tv" -> true; "movie" -> false; else -> return }
                if ((c["adult"] as? JsonPrimitive)?.booleanOrNull == true) return
                val genres = (c["genre_ids"] as? JsonArray).orEmpty().mapNotNull { (it as? JsonPrimitive)?.intOrNull }
                if (series && genres.any { it == 10767 || it == 10763 }) return
                val id = c["id"]?.jsonPrimitive?.longOrNull ?: return
                val title = (if (series) c.str("name") else c.str("title")) ?: c.str("title") ?: c.str("name") ?: return
                val date = (if (series) c.str("first_air_date") else c.str("release_date"))
                val poster = c.str("poster_path")?.let { "${base}w342$it" }
                if (date == null && poster == null) return
                val votes = c["vote_count"]?.jsonPrimitive?.intOrNull
                val credit = Credit(id, series, title, (if (series) c.str("original_name") else c.str("original_title"))?.takeIf { it != title }, year(date), date, poster,
                    DisplayRating.credible(c["vote_average"]?.jsonPrimitive?.doubleOrNull, votes), c["popularity"]?.jsonPrimitive?.doubleOrNull ?: 0.0, c.str("overview"), role, c["order"]?.jsonPrimitive?.intOrNull)
                val old = out[credit.key]
                if (old == null) out[credit.key] = credit else if (role != null && old.role != null && role !in old.role.split(" / ")) out[credit.key] = old.copy(role = old.role + " / " + role)
            }
            for (e in cast) add(e, (e as? JsonObject)?.str("character"))
            if (wantCrew) for (e in crew) { val job = (e as? JsonObject)?.str("job"); if (job == "Director" || job == "Creator") add(e, job) }
            return out.values.toList()
        }

        /** The person's results of a name search: (id, name, titles they are known for). */
        fun parseSearch(json: String): List<Triple<Long, String, List<String>>> = ((Xtream.parseObject(json)?.get("results") as? JsonArray).orEmpty()).mapNotNull { e ->
            val o = e as? JsonObject ?: return@mapNotNull null
            val known = (o["known_for"] as? JsonArray).orEmpty().mapNotNull { (it as? JsonObject)?.let { k -> k.str("title") ?: k.str("name") } }
            Triple(o["id"]?.jsonPrimitive?.longOrNull ?: return@mapNotNull null, o.str("name") ?: return@mapNotNull null, known)
        }

        /** The exact-name result whose known_for titles overlap the title the person was tapped from (else the first exact-name result, else none). */
        fun choosePerson(results: List<Triple<Long, String, List<String>>>, name: String, fromTitle: String?): Long? {
            val want = IdentityKey.normalize(name)
            val exact = results.filter { IdentityKey.normalize(it.second) == want }
            if (exact.isEmpty()) return null
            val from = fromTitle?.let { IdentityKey.ofOrFallback(it) }
            if (from != null) exact.firstOrNull { r -> r.third.any { IdentityKey.ofOrFallback(it) == from } }?.let { return it.first }
            return exact.first().first
        }
    }

    private fun file(id: Long, lang: String) = File(dir, "$PREFIX$id-${lang.lowercase().filter { it.isLetter() || it == '-' }.ifEmpty { "en" }}.json")
    private fun age(f: File) = now() - f.lastModified()

    /** The saved copy, however old (it is shown at once while a fresh one is asked for), or null. */
    fun cached(id: Long, lang: String = "en"): Filmography? = file(id, lang).takeIf { it.isFile && age(it) < TmdbFiles.MAX_DAYS * TmdbFiles.DAY_MS }?.let { f -> runCatching { readSaved(f.readText()) }.getOrNull() }
    fun isFresh(id: Long, lang: String = "en"): Boolean = file(id, lang).let { it.isFile && age(it) < TmdbFiles.SOFT_DAYS * TmdbFiles.DAY_MS }

    /** Asks TMDB (the app's language first, English when the biography came back empty) and saves the answer. Throws when the network or TMDB fails: the caller keeps what it shows. */
    fun load(id: Long, lang: String = "en"): Filmography {
        if (!auth.available) throw java.io.IOException("TMDB is not available.")
        fun person(l: String) = parsePerson(auth.call("person/$id", "append_to_response=images&language=${enc(l)}", fetch))
        var p = person(lang)
        if (p != null && p.biography.isNullOrBlank() && !lang.startsWith("en")) p = person("en-US")?.let { en -> p!!.copy(biography = en.biography) }
        val credits = parseCredits(auth.call("person/$id/combined_credits", "", fetch), p?.department)
        return Filmography(p, credits).also { save(file(id, lang), it) }
    }

    /** The TMDB id of a person known only by name: an exact-name search that prefers the result known for the title they were tapped from. Null when nothing fits. */
    fun resolve(name: String, fromTitle: String?): Long? {
        if (!auth.available || name.isBlank()) return null
        val f = File(dir, "${PREFIX}find-" + sha(IdentityKey.normalize(name) + "|" + (fromTitle?.let { IdentityKey.ofOrFallback(it) } ?: "")) + ".json")
        if (f.isFile && age(f) < TmdbFiles.SOFT_DAYS * TmdbFiles.DAY_MS) runCatching { f.readText().trim().toLong() }.getOrNull()?.let { return it }
        val id = choosePerson(parseSearch(auth.call("search/person", "query=${enc(name.trim())}", fetch)), name, fromTitle) ?: return null
        dir.mkdirs(); f.writeText(id.toString())
        return id
    }

    private fun save(f: File, d: Filmography) {
        dir.mkdirs()
        f.writeText(buildJsonObject {
            d.person?.let { p -> put("p", buildJsonObject { put("i", p.id); put("n", p.name); p.biography?.let { put("b", it) }; p.photo?.let { put("f", it) }; p.department?.let { put("d", it) }; p.born?.let { put("bo", it) }; p.died?.let { put("di", it) }; p.birthPlace?.let { put("pl", it) }
                put("a", buildJsonArray { p.alsoKnownAs.forEach { add(it) } }); put("ph", buildJsonArray { p.photos.forEach { add(it) } }) }) }
            put("c", buildJsonArray { d.credits.forEach { c -> add(buildJsonObject { put("i", c.tmdbId); put("s", c.series); put("t", c.title); c.original?.let { put("o", it) }; c.date?.let { put("d", it) }; c.poster?.let { put("p", it) }; c.rating?.let { put("r", it) }; put("pop", c.popularity); c.overview?.let { put("ov", it) }; c.role?.let { put("ro", it) }; c.order?.let { put("od", it) } }) } })
        }.toString())
    }
    private fun readSaved(text: String): Filmography {
        val o = Json.parseToJsonElement(text).jsonObject
        val p = (o["p"] as? JsonObject)?.let { j -> fun s(k: String) = j[k]?.jsonPrimitive?.contentOrNull
            PersonInfo(j["i"]!!.jsonPrimitive.long, s("n")!!, s("b"), s("f"), s("d"), s("bo"), s("di"), s("pl"), (j["a"] as? JsonArray).orEmpty().map { it.jsonPrimitive.content }, (j["ph"] as? JsonArray).orEmpty().map { it.jsonPrimitive.content }) }
        val credits = (o["c"] as JsonArray).map { e -> val j = e.jsonObject; fun s(k: String) = j[k]?.jsonPrimitive?.contentOrNull
            val d = s("d")
            Credit(j["i"]!!.jsonPrimitive.long, j["s"]!!.jsonPrimitive.boolean, s("t")!!, s("o"), year(d), d, s("p"), j["r"]?.jsonPrimitive?.doubleOrNull, j["pop"]?.jsonPrimitive?.doubleOrNull ?: 0.0, s("ov"), s("ro"), j["od"]?.jsonPrimitive?.intOrNull) }
        return Filmography(p, credits)
    }
}

/** Where a library item is known by its TMDB id, when the app stores one (no such store exists yet; the hook makes an exact match win the day one does). */
fun interface LibraryTmdbIds { fun itemIds(tmdbId: Long, series: Boolean): List<String> }

/**
 * Which credits are in the library. Local only: by a stored TMDB id (exact), else by the cleaned name's identity key (the same rule that folds language versions and twin copies) and a year within one.
 * All copies of a title fold into one hit (with their count); the copy of the earliest source in [sources] stands for it. A title with any copy in a restricted place (locked, hidden, adult, or a twin
 * of one) is never a hit.
 */
class LibraryMatcher(private val db: AppDatabase, private val visibility: Visibility, private val ids: LibraryTmdbIds = LibraryTmdbIds { _, _ -> emptyList() }) {
    suspend fun match(credits: List<Credit>, sources: List<String>): Map<String, LibraryHit> {
        if (credits.isEmpty() || sources.isEmpty()) return emptyMap()
        val snap = visibility.snapshot(Visibility.Surface.RECOMMEND)
        val keysOf = credits.associate { c -> c.key to listOfNotNull(c.title, c.original).map { IdentityKey.ofOrFallback(it) }.filter { it.isNotEmpty() }.distinct() }
        // candidate rows by identity key
        val rows = HashMap<String, MutableList<app.streamsetu.core.data.db.ContentIdentityEntity>>()          // kind|key -> rows
        for (kind in listOf("MOVIE", "SERIES")) {
            val keys = credits.filter { it.series == (kind == "SERIES") }.flatMap { keysOf[it.key].orEmpty() }.distinct()
            for (chunk in keys.chunked(300)) for (r in db.identity().byKeys(kind, chunk, sources)) rows.getOrPut(kind + "|" + r.identityKey) { ArrayList(2) } += r
        }
        val out = LinkedHashMap<String, LibraryHit>()
        for (c in credits) {
            val kind = if (c.series) "SERIES" else "MOVIE"
            val exact = ids.itemIds(c.tmdbId, c.series)
            val cand = LinkedHashMap<String, String>()          // itemId -> sourceId
            for (id in exact) cand[id] = ""
            for (k in keysOf[c.key].orEmpty()) for (r in rows[kind + "|" + k].orEmpty()) {
                val ok = when {
                    c.year == null -> false
                    r.year == null -> k.contains(' ')
                    else -> kotlin.math.abs(r.year!! - c.year) <= 1
                }
                if (ok) cand[r.itemId] = r.sourceId
            }
            if (cand.isEmpty()) continue
            val idList = cand.keys.toList()
            if (c.series) {
                val l = idList.chunked(400).flatMap { db.catalog().seriesByIds(it) }.filter { it.sourceId in sources }
                if (l.isEmpty() || l.any { !snap.seriesOk(it.toModel()) }) continue
                val rep = l.minWith(compareBy({ sources.indexOf(it.sourceId) }, { it.id })).toModel()
                out[c.key] = LibraryHit(null, rep, l.size)
            } else {
                val l = idList.chunked(400).flatMap { db.catalog().moviesByIds(it) }.filter { it.sourceId in sources }
                if (l.isEmpty() || l.any { !snap.movieOk(it.toModel()) }) continue
                val rep = l.minWith(compareBy({ sources.indexOf(it.sourceId) }, { -it.addedAt }, { it.id })).toModel()
                out[c.key] = LibraryHit(rep, null, l.size)
            }
        }
        return out
    }
}

/** The short lines of the person header, as text (so they can be tested and read the same on every screen). */
object PersonText {
    private val months = listOf("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
    private fun parts(d: String?): Triple<Int, Int, Int>? { val p = d?.take(10)?.split('-')?.mapNotNull { it.toIntOrNull() }; return if (p != null && p.size == 3 && p[1] in 1..12 && p[2] in 1..31) Triple(p[0], p[1], p[2]) else null }
    private fun fmt(t: Triple<Int, Int, Int>) = "${t.third} ${months[t.second - 1]} ${t.first}"

    /** "Born 24 Aug 1975 (age 51) · Hyderabad, India"; with a death date "Born ... · Died ... (aged 80)". Null when nothing is known. */
    fun born(p: PersonInfo, nowMs: Long = System.currentTimeMillis()): String? {
        val b = parts(p.born); val d = parts(p.died)
        val now = java.util.Calendar.getInstance().apply { timeInMillis = nowMs }
        val ny = now.get(java.util.Calendar.YEAR); val nm = now.get(java.util.Calendar.MONTH) + 1; val nd = now.get(java.util.Calendar.DAY_OF_MONTH)
        fun age(to: Triple<Int, Int, Int>) = if (b == null) null else (to.first - b.first - if (to.second < b.second || (to.second == b.second && to.third < b.third)) 1 else 0).takeIf { it in 0..130 }
        val first = when {
            b == null -> null
            d != null -> "Born ${fmt(b)} · Died ${fmt(d)}" + (age(d)?.let { " (aged $it)" } ?: "")
            else -> "Born ${fmt(b)}" + (age(Triple(ny, nm, nd))?.let { " (age $it)" } ?: "")
        }
        return listOfNotNull(first, p.birthPlace?.takeIf { it.isNotBlank() }).joinToString(" · ").ifEmpty { null }
    }
    /** "Acting · Pokiri, Dookudu, Businessman". */
    fun knownFor(department: String?, titles: List<String>): String? = listOfNotNull(department?.takeIf { it.isNotBlank() }, titles.take(4).joinToString(", ").ifEmpty { null }).joinToString(" · ").ifEmpty { null }
    /** "Also known as" only when it is short. */
    fun alsoKnownAs(p: PersonInfo, maxChars: Int = 60): String? = p.alsoKnownAs.take(3).joinToString(", ").takeIf { it.isNotEmpty() && it.length <= maxChars }
}
