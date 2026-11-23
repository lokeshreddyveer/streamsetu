package app.streamsetu.core.model

/**
 * The key a title is ordered by in "A to Z" over the whole library (column `titleSort`, kept by two triggers). SQLite's lower() only changes A to Z, so "Émile", "Ørsted" and "Ünal" used to sort after "Z".
 * This key lower-cases A to Z and folds the Latin letters with accents to their plain letters ("é" and "É" to "e", "ß" to "ss"); every other character (Devanagari, Telugu, Arabic, Chinese ...) is left as it is, so such
 * titles still order by code point. The same table builds the trigger expression ([sqlExpression]) and the Kotlin key ([of]), so a page cursor built in Kotlin equals the stored column exactly.
 */
object SortKey {
    private val groups: List<Pair<String, String>> = listOf(
        "àáâãäåāăą" to "a", "çćĉċč" to "c", "ďđ" to "d", "èéêëēĕėęě" to "e", "ĝğġģ" to "g", "ĥħ" to "h", "ìíîïĩīĭįı" to "i", "ĵ" to "j", "ķ" to "k", "ĺļľŀł" to "l",
        "ñńņň" to "n", "òóôõöøōŏő" to "o", "ŕŗř" to "r", "śŝşš" to "s", "ţťŧ" to "t", "ùúûüũūŭůűų" to "u", "ŵ" to "w", "ýÿŷ" to "y", "źżž" to "z",
    )
    private val specials: List<Pair<Char, String>> = listOf('ß' to "ss", 'æ' to "ae", 'œ' to "oe")

    /** Character -> replacement, both the lower-case and the upper-case form of every accented letter. */
    val table: Map<Char, String> = LinkedHashMap<Char, String>().also { m ->
        for ((chars, base) in groups) for (c in chars) { m[c] = base; val u = c.uppercaseChar(); if (u != c && u.code > 127) m[u] = base }
        for ((c, r) in specials) { m[c] = r; val u = c.uppercaseChar(); if (u != c && u.code > 127) m[u] = r }
    }

    fun of(title: String): String {
        val sb = StringBuilder(title.length)
        for (ch in title) { val r = table[ch]; if (r != null) sb.append(r) else sb.append(if (ch in 'A'..'Z') ch + 32 else ch) }
        return sb.toString()
    }

    /** SQLite stops parsing an expression nested about a hundred deep ("parser stack overflow"), so the folded characters go in several UPDATE steps of [CHUNK] nested replace() calls each. */
    const val CHUNK = 12

    /**
     * The UPDATE statements that set `titleSort` of the rows matching [where] to the key of [source] (a column or `NEW.title`): the first lower-cases and folds the first characters, each
     * next one folds the next characters of the value already stored. Run them in this order (as one trigger body, or one after the other in a migration).
     */
    fun updateStatements(table: String, source: String, where: String): List<String> =
        this.table.entries.chunked(CHUNK).mapIndexed { i, part ->
            var e = if (i == 0) "lower($source)" else "titleSort"
            for ((c, r) in part) e = "replace($e,'$c','$r')"
            "UPDATE $table SET titleSort = $e WHERE $where"
        }

    /** True when the title has a character outside printable ASCII: only those rows can change when the key changes. */
    const val NON_ASCII_GLOB = "*[^ -~]*"
}
