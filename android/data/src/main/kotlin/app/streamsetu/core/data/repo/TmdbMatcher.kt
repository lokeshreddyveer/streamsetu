package app.streamsetu.core.data.repo

import app.streamsetu.core.model.putIfMissing
import app.streamsetu.core.net.HttpStatusException
import app.streamsetu.core.parse.Xtream
import app.streamsetu.core.parse.str
import kotlinx.serialization.json.*

/**
 * Finds the one TMDB title a library title means (engine v2). A title the provider gave a TMDB id for is fetched by it, with no search. Otherwise: one search for the cleaned name without the
 * year (en-US, no adult titles) and the choice made locally by [ArtworkMatchDecision]; only when that finds nothing sure, at most three more: with the year (when the first answer was a full
 * page, so the year can surface more), without the last word, without the first word. A title is never given a picture unless the decision is sure; two equally good answers leave it unmatched.
 */
class TmdbMatcher(private val auth: TmdbAuth, private val http: TmdbCall = tmdbHttp) {
    data class Candidate(val id: Long, val title: String, val original: String?, val year: Int?, val popularity: Double, val poster: String?, val backdrop: String?, val plot: String?, val originalLanguage: String? = null)
    data class Match(val id: Long, val title: String, val year: Int?, val posterUrl: String?, val backdropUrl: String?, val plot: String?)

    companion object {
        const val MAX_RESULTS = 20
        /** The extra NAME-only attempts, in order: cut at a Season/Episode marker, cut at a year that follows a word, without a trailing language word, without a leading one. */
        val ALL_TIERS = setOf("season", "year", "lang-tail", "lang-head")
        private val seasonCut = Regex("(?i)\\s+(?:(?:season|series|saison|temporada|staffel)\\s*\\d+|episode\\s*\\d+|ep\\s*\\d+|s\\d{1,2}\\s?e\\d{1,3})\\b.*$")
        private val yearCut = Regex("\\s+(?:19\\d{2}|20[0-2]\\d|2030)\\b.*$")
        val languageWords: Set<String> = setOf("telugu", "hindi", "tamil", "malayalam", "kannada", "bengali", "punjabi", "marathi", "gujarati", "urdu", "turkish", "english", "arabic", "korean", "japanese", "spanish", "french", "german", "chinese", "thai", "portuguese", "italian", "russian", "indonesian", "dutch", "polish", "persian", "hebrew", "vietnamese", "odia", "multi", "dual", "dubbed", "subbed", "sub", "dub")
        fun extraQueries(text: String, tiers: Set<String> = ALL_TIERS): List<String> {
            val out = ArrayList<String>()
            fun add(t: String) { val x = t.trim(' ', '-', ':', '|', ','); if (x.length >= 2 && x != text && x !in out) out.add(x) }
            if ("season" in tiers) seasonCut.find(text)?.let { add(text.substring(0, it.range.first)) }
            if ("year" in tiers) yearCut.find(text)?.let { if (it.range.first > 1) add(text.substring(0, it.range.first)) }
            val words = text.split(' ').filter { it.isNotEmpty() }
            if ("lang-tail" in tiers && words.size >= 2 && words.last().lowercase() in languageWords) add(words.dropLast(1).joinToString(" "))
            if ("lang-head" in tiers && words.size >= 2 && words.first().lowercase() in languageWords) add(words.drop(1).joinToString(" "))
            return out
        }
        private val eventWords = Regex("(?i)\\b(highlights|press conference|post[- ]?match|pre[- ]?match|weigh[- ]?in|ppv|full match|full replay)\\b")
        private val versus = Regex("(?i)\\S\\s+vs\\.?\\s+\\S")
        private val hasYear = Regex("\\b(19|20)\\d{2}\\b")
        /** A name that is not a title: a fixture of two sides without a year, or a recording of an event. Never looked up, never counted. */
        fun isNonTitle(raw: String, year: Int?): Boolean = eventWords.containsMatchIn(raw) || (year == null && versus.containsMatchIn(raw) && !hasYear.containsMatchIn(raw))

        private fun candidateOf(o: JsonObject, kind: String): Candidate {
            val movie = kind == "movie"
            val title = (if (movie) o.str("title") else o.str("name")) ?: o.str("title") ?: o.str("name")
            return Candidate(o["id"]?.jsonPrimitive?.longOrNull ?: 0L, title ?: "", (if (movie) o.str("original_title") else o.str("original_name")),
                (if (movie) o.str("release_date") else o.str("first_air_date"))?.take(4)?.toIntOrNull(), o["popularity"]?.jsonPrimitive?.doubleOrNull ?: 0.0,
                o.str("poster_path")?.let { "https://image.tmdb.org/t/p/w342$it" }, o.str("backdrop_path")?.let { "https://image.tmdb.org/t/p/w780$it" }, o.str("overview"), o.str("original_language"))
        }

        fun parseResults(json: String, kind: String): List<Candidate> {
            val arr = (Xtream.parseObject(json)?.get("results") as? JsonArray) ?: return emptyList()
            return arr.take(MAX_RESULTS).mapNotNull { e -> (e as? JsonObject)?.let { candidateOf(it, kind) } }
        }
        fun parseOne(json: String, kind: String): Candidate? = Xtream.parseObject(json)?.takeIf { it["id"] != null }?.let { candidateOf(it, kind) }

        fun decisionCandidate(c: Candidate) = ArtworkMatchDecision.Candidate(c.id, c.title.ifEmpty { null }, c.original, c.year, c.popularity, c.originalLanguage)
    }

    private val ids = object : LinkedHashMap<String, Long>(64, 0.75f, true) { override fun removeEldestEntry(e: MutableMap.MutableEntry<String, Long>?) = size > 128 }

    private fun toMatch(c: Candidate) = Match(c.id, c.title, c.year, c.poster, c.backdrop, c.plot)

    /** The title the provider named by its TMDB id (no search), or null when TMDB does not know that id. */
    fun byProviderId(kind: String, tmdbId: Long): Match? = try {
        parseOne(auth.call("$kind/$tmdbId", "language=en-US", http), kind)?.let(::toMatch)
    } catch (e: HttpStatusException) { if (e.code == 404) null else throw e }

    /** The match for a library title, or null when TMDB has none we are sure of. Network errors are thrown. [languageTag] is the library's language for it ("Telugu"). */
    @Volatile var extraTiers: Set<String> = setOf("year", "lang-tail", "lang-head")   // "season" is off: the name cleaner already cuts there (measured: no gain)

    fun match(kind: String, raw: String, libYear: Int?, languageTag: String = "", providerTmdbId: Long? = null, folderName: String = ""): Match? {
        providerTmdbId?.let { id -> byProviderId(kind, id)?.let { return it } }
        if (isNonTitle(raw, libYear)) return null
        var parsed = ArtworkNames.parse(raw, libYear)
        // A name that cleans to nothing ("S01E04") borrows the folder's name.
        if ((parsed.text.isEmpty() || markerOnly.matches(parsed.text)) && folderName.isNotEmpty()) parsed = ArtworkNames.parse(folderName, libYear)
        val text = parsed.text
        if (text.length < 2 || markerOnly.matches(text)) return null
        // One resolution per series (or title) per run: every episode and sibling whose name cleans to the same text inherits the first answer.
        val key = kind + "|" + ArtworkMatchDecision.canon(text)
        synchronized(runCache) { if (runCache.containsKey(key)) return runCache[key] }
        val m = resolve(kind, raw, text, parsed.year, languageTag)
        synchronized(runCache) { if (runCache.size >= 8192) runCache.clear(); runCache[key] = m }
        return m
    }

    private val markerOnly = Regex("(?i)^(s\\d{1,2}\\s?e\\d{1,3}|\\d{1,2}x\\d{1,3}|(episode|ep|episodio|folge|e)\\s?\\d{1,3})$")

    /** Answers found in this run, by kind and normalised cleaned name (null answers included; a thrown error is never kept). */
    private val runCache = HashMap<String, Match?>()
    fun clearRunCache() { synchronized(runCache) { runCache.clear() } }

    /** The offline alias index, when one is loaded (consulted by name only). */
    @Volatile var aliasIndex: AliasIndex? = null
        get() { if (field == null && !aliasTried) synchronized(this) { if (!aliasTried) { aliasTried = true; field = aliasSource?.let { runCatching { it()?.let(AliasIndex::parse) }.getOrNull() } } }; return field }
    /** Where the shipped file is read from (the app gives its assets); read once, on first use. */
    @Volatile var aliasSource: (() -> ByteArray?)? = null
    @Volatile private var aliasTried = false

    /** Both alias tiers are OFF by default: measured with the seed index, exact added 6 wrong and no recall, phonetic +0.2 pt for +6 wrong. */
    @Volatile var aliasExactEnabled = false
    @Volatile var aliasPhoneticEnabled = false

    private fun aliasHit(kind: String, text: String, phonetic: Boolean): Match? {
        if (!(if (phonetic) aliasPhoneticEnabled else aliasExactEnabled)) return null
        val idx = aliasIndex ?: return null
        val e = (if (phonetic) idx.phonetic(text, kind == "tv")?.first else idx.exact(text, kind == "tv")) ?: return null
        return byProviderId(kind, e.tmdbId)
    }

    private fun resolve(kind: String, raw: String, text: String, year: Int?, languageTag: String): Match? {
        val q = ArtworkMatchDecision.Query(raw, year, kind == "tv", languageTag)
        val seen = LinkedHashMap<Long, Candidate>()
        fun search(query: String): List<Candidate> {
            val found = parseResults(auth.call("search/$kind", "query=${enc(query)}&include_adult=false&language=en-US", http), kind)
            for (c in found) seen.putIfMissing(c.id, c)
            return found
        }
        fun decide(t: String = text): Match? = ArtworkMatchDecision.decide(q, seen.values.map(::decisionCandidate), t)?.let { seen[it] }?.let(::toMatch)
        search(text)
        decide()?.let { remember(kind, text, year, it); return it }
        aliasHit(kind, text, false)?.let { remember(kind, text, year, it); return it }
        val words = text.split(' ').filter { it.isNotEmpty() }
        // A year left on the end of the name ("Hospital Playlist 2020") is searched without it (never used to decide).
        if (words.size >= 2 && words.last().length == 4 && words.last().toIntOrNull()?.let { it in 1900..2030 } == true) {
            val t = words.dropLast(1).joinToString(" "); search(t); decide(t)?.let { remember(kind, text, year, it); return it }
        }
        if (words.size >= 3) { search(words.dropLast(1).joinToString(" ")); decide()?.let { remember(kind, text, year, it); return it } }
        if (words.size >= 3) { search(words.drop(1).joinToString(" ")); decide()?.let { remember(kind, text, year, it); return it } }
        for (t in extraQueries(text, extraTiers)) { search(t); decide(t)?.let { remember(kind, text, year, it); return it } }
        aliasHit(kind, text, true)?.let { remember(kind, text, year, it); return it }
        return null
    }

    private fun remember(kind: String, text: String, year: Int?, m: Match) { synchronized(ids) { ids["$kind|${text.lowercase()}|$year"] = m.id } }
}
