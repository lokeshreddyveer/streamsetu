package app.streamsetu.core.data.repo

import kotlin.math.abs
import kotlin.math.ln
import kotlin.math.sqrt

/**
 * "More like this": ranks a pool of titles by how much they resemble one title. It uses only what is on the device, plus the genre, cast and director the provider
 * sends for the open title and (when known) for a candidate. Nothing is invented: a title with no shared signal scores nothing and is left out.
 *
 * Signals, strongest first: the same franchise (a sequel, a prequel, another film of the series), the same director, the same genre, shared cast, a similar story
 * (words of the plot that are rare in the pool), the same language, a close year, a close rating, and the same provider folder.
 */
object Similarity {
    data class Item(val id: String, val title: String, val year: Int?, val rating: Double?, val plot: String?, val folder: String?)
    data class Facts(val genres: Set<String> = emptySet(), val cast: Set<String> = emptySet(), val directors: Set<String> = emptySet()) {
        val isEmpty get() = genres.isEmpty() && cast.isEmpty() && directors.isEmpty()
    }
    data class Result(val id: String, val score: Double, val reason: String)

    private val languages = setOf("english", "hindi", "tamil", "telugu", "kannada", "malayalam", "urdu", "punjabi", "bengali", "marathi", "gujarati", "arabic", "spanish", "french", "german", "korean", "japanese", "chinese", "turkish", "russian", "italian", "portuguese", "thai", "indonesian")
    private val noise = setOf("hd", "fhd", "uhd", "4k", "sd", "hdcam", "cam", "webrip", "web", "dl", "bluray", "dvdrip", "hevc", "x264", "x265", "h264", "h265", "dubbed", "dub", "multi", "sub", "subs", "eng", "season", "episode")
    private val stop = ("the a an and or of to in on at for with from by is are was were be been it its this that these those his her their they them he she we you i as but not no so if then than " +
        "who whom what when where why how into out up down over under about after before while during against between through only also just very more most some any all each one two when has have had will would could should can may might own other such")
        .split(' ').toSet()
    private val roman = Regex("^(ii|iii|iv|v|vi|vii|viii|ix|x)$")

    fun normalize(s: String) = SearchText.normalize(s)

    /** The language written in a title or folder name: "Tamil", from "Sully (2016) (Tamil)" or "ENGLISH | FHD". */
    fun languageOf(vararg texts: String?): String? = texts.asSequence().filterNotNull().flatMap { normalize(it).split(' ').asSequence() }.firstOrNull { it in languages }

    private val markerWords = setOf("part", "chapter", "vol", "volume")

    /** The words of a title's main part (before a colon or a dash) once the year, quality tags and language are removed. */
    private fun headWords(title: String): MutableList<String> {
        val head = title.substringBefore(':').substringBefore(" - ")
        return normalize(head).split(' ').filter { it.isNotEmpty() }
            .filter { !(it.length == 4 && it.all(Char::isDigit) && (it.startsWith("19") || it.startsWith("20"))) && it !in noise && it !in languages }.toMutableList()
    }

    private fun isMarker(w: String) = w.all(Char::isDigit) || roman.matches(w) || w in markerWords

    /** What is left of a title once the year, quality, language and sequel markers are removed: "Rolling Loud: The Movie (2026) (HDCAM)" becomes "rolling loud". */
    fun stem(title: String): String {
        val words = headWords(title)
        while (words.size > 1 && isMarker(words.last())) words.removeAt(words.size - 1)
        return words.joinToString(" ")
    }

    /** True for "John Wick 3", "Mission Impossible II", "Rocky Part 2": the title carries a sequel number. */
    fun sequelMarked(title: String): Boolean = headWords(title).let { it.size > 1 && isMarker(it.last()) }

    /** A title with only its year, quality tags and language removed: two titles with the same identity are the same film or show (a dub, another quality), not a suggestion for each other. */
    fun identity(title: String): String = normalize(title).split(' ').filter { it.isNotEmpty() && !(it.length == 4 && it.all(Char::isDigit) && (it.startsWith("19") || it.startsWith("20"))) && it !in noise && it !in languages }.joinToString(" ")

    private val leadingArticle = Regex("^(the|a|an) ")
    private fun lead(stem: String) = leadingArticle.replace(stem, "")

    private val smallWords = setOf("its", "a", "an", "the", "i", "my", "me", "in", "on", "of", "to", "and", "is", "are", "one", "all", "no", "you", "we", "our", "your", "this", "that", "with", "from", "for", "not", "too", "his", "her", "how", "what", "when", "who")

    private fun sameFranchise(a: String, b: String): Boolean {
        val x0 = lead(a); val y0 = lead(b)
        if (x0.isEmpty() || y0.isEmpty()) return false
        if (x0 == y0) return true
        val x = x0.split(' '); val y = y0.split(' ')
        // The first two words must match. Leading articles are ignored, so "The Amazing Spider-Man" is not "The Amazing Bulk", and two small words
        // alone ("It's a Medical Miracle", "It's a Good Day to Die") do not make a franchise: one of the two has to be a word with some weight.
        if (x.size < 2 || y.size < 2 || x[0] != y[0] || x[1] != y[1]) return false
        return x.take(2).any { it.length >= 4 && it !in smallWords }
    }

    /**
     * The films of the same franchise as [target], with the target among them, in the order they came out. A sequel or another film of the series counts (the first words of the
     * title match once the year, quality, language and sequel number are removed); a dub or another quality of the same film does not appear twice. Fewer than two films is no
     * franchise, and the result is empty.
     */
    fun franchise(target: Item, pool: List<Item>, limit: Int = 12): List<Item> {
        val stem = stem(target.title)
        if (stem.isEmpty()) return emptyList()
        val oneWord = lead(stem).split(' ').size == 1
        // A one-word name ("Crash", "Heat") is a franchise only through a sequel number: two unrelated films can share it.
        val siblings = pool.filter { it.id != target.id && sameFranchise(stem, stem(it.title)) && (!oneWord || sequelMarked(it.title) || sequelMarked(target.title)) }
        // Provider titles carry tags in every shape ("[Tam, Tel, Hin]", "(Telugu)", "(4K)"), so copies of one film are told apart by its release year, not by its name.
        val byFilm = LinkedHashMap<String, Item>()
        for (c in listOf(target) + siblings) {
            val key = c.year?.toString() ?: identity(c.title)
            val have = byFilm[key]
            if (have == null) byFilm[key] = c
            else if (have.id != target.id && (c.id == target.id || score(c) > score(have) || (score(c) == score(have) && c.title.length < have.title.length))) byFilm[key] = c
        }
        if (byFilm.size < 2) return emptyList()
        return byFilm.values.sortedWith(compareBy<Item>({ it.year ?: Int.MAX_VALUE }, { it.title })).take(limit)
    }

    private fun score(i: Item) = if ((i.rating ?: 0.0) > 0) 1 else 0

    private fun words(plot: String?): Set<String> = if (plot.isNullOrBlank()) emptySet() else normalize(plot).split(' ').filter { it.length >= 4 && it !in stop && it !in languages }.toSet()

    /** Genre, cast and director as sets of lower-case names, from the provider's comma or slash separated text. */
    fun facts(genre: String?, cast: String?, director: String?): Facts {
        fun parts(s: String?, seps: Regex) = s?.split(seps)?.map { normalize(it) }?.filter { it.length >= 3 }?.toSet().orEmpty()
        return Facts(parts(genre, Regex("[,/|&]")), parts(cast, Regex("[,;]")), parts(director, Regex("[,;/&]")))
    }

    /**
     * [known] holds the facts of candidates the provider has already been asked about. The pool should not contain the target itself or another copy of the same title
     * (those are "other sources", not suggestions); both are dropped here too.
     */
    fun rank(target: Item, targetFacts: Facts?, pool: List<Item>, known: Map<String, Facts> = emptyMap(), limit: Int = 30): List<Result> {
        val tStem = stem(target.title); val tId = identity(target.title)
        val tWords = words(target.plot)
        val tLang = languageOf(target.title, target.folder)
        // One suggestion per film: dubs and quality copies of it carry different tags but share a name and a year.
        val seen = HashSet<String>()
        val candidates = pool.filter { it.id != target.id && identity(it.title) != tId && seen.add("${stem(it.title)}|${it.year ?: 0}") }
        // How rare a plot word is in this pool: a word in every plot says nothing, a word in three says a lot.
        val df = HashMap<String, Int>()
        val candWords = candidates.associate { it.id to words(it.plot) }
        candWords.values.forEach { ws -> ws.forEach { df[it] = (df[it] ?: 0) + 1 } }
        val n = candidates.size.coerceAtLeast(1)
        fun idf(w: String) = ln((n + 1.0) / (1 + (df[w] ?: 0))) + 0.1
        val tNorm2 = sqrt(tWords.sumOf { idf(it) * idf(it) }).takeIf { it > 0 }

        val out = ArrayList<Result>()
        val weak = ArrayList<Result>()
        for (c in candidates) {
            var total = 0.0; var best = 0.0; var reason = ""
            fun add(points: Double, why: String) { if (points <= 0) return; total += points; if (points > best) { best = points; reason = why } }
            if (sameFranchise(tStem, stem(c.title))) add(7.0, "Same franchise")
            val cf = known[c.id]
            if (targetFacts != null && cf != null) {
                val dir = targetFacts.directors.intersect(cf.directors).size
                if (dir > 0) add(5.0, "Same director")
                val g = targetFacts.genres.intersect(cf.genres).size
                if (g > 0) add(3.0 + 1.5 * minOf(g, 3), "Same genre")
                val cast = targetFacts.cast.intersect(cf.cast).size
                if (cast > 0) add(minOf(cast, 3) * 2.0, "Shared cast")
            } else if (targetFacts != null) {
                // Not asked about yet: a name or genre of the open title written in this plot is a weaker hint of the same thing.
                val text = normalize(c.plot.orEmpty() + " " + c.title)
                val named = (targetFacts.directors + targetFacts.cast).count { it.length >= 5 && text.contains(it) }
                if (named > 0) add(minOf(named, 2) * 2.0, "Shared cast")
            }
            val cw = candWords[c.id].orEmpty()
            if (tNorm2 != null && cw.isNotEmpty()) {
                val shared = tWords.intersect(cw)
                if (shared.isNotEmpty()) {
                    val dot = shared.sumOf { idf(it) * idf(it) }
                    val cNorm = sqrt(cw.sumOf { idf(it) * idf(it) })
                    add(minOf(6.0, 14.0 * dot / (tNorm2 * cNorm)), "Similar story")
                }
            }
            val cLang = languageOf(c.title, c.folder)
            if (tLang != null && cLang != null) { if (tLang == cLang) add(1.5, "Same language") else total -= 2.0 }
            if (target.year != null && c.year != null) add(1.5 * maxOf(0.0, 1 - abs(target.year - c.year) / 12.0), "Close in time")
            if (target.rating != null && c.rating != null && target.rating > 0 && c.rating > 0) add(1.2 * maxOf(0.0, 1 - abs(target.rating - c.rating) / 3.0), "Rated alike")
            if (target.folder != null && target.folder == c.folder) add(1.0, "From the same folder")
            // Only titles with a real reason are suggested: closeness in year or rating alone is not enough.
            val meaningful = reason in setOf("Same franchise", "Same director", "Same genre", "Shared cast", "Similar story")
            if (meaningful && total > 1.0) out += Result(c.id, total + (c.rating ?: 0.0) / 100.0, reason) else if (total > 1.0) weak += Result(c.id, total, reason)
        }
        // When there is too little to go on (no plots, no facts), fall back to the same folder so the row is never empty.
        if (out.size < 6 && target.folder != null) {
            val have = out.map { it.id }.toSet()
            candidates.filter { it.id !in have && it.folder == target.folder }.sortedWith(compareBy({ -(it.rating ?: 0.0) }, { abs((it.year ?: 0) - (target.year ?: 0)) })).take(10 - out.size)
                .forEach { out += Result(it.id, 0.5, "From the same folder") }
        }
        // Still thin (a catalog with no plots, genres or facts): add the closest by language, year and rating, saying so.
        if (out.size < 6) { val have = out.map { it.id }.toSet(); weak.filter { it.id !in have }.sortedByDescending { it.score }.take(10 - out.size).forEach { out += it.copy(score = 0.4, reason = if (it.reason == "Same language") "Same language" else "Similar year and rating") } }
        return out.sortedByDescending { it.score }.take(limit)
    }
}
