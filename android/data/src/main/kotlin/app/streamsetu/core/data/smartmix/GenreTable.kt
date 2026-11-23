package app.streamsetu.core.data.smartmix

enum class GenreScope { BOTH, MOVIE, SERIES }

/** One row of the genre table (docs/SMART-MIX.md section 1; `table` of genre-shelves.json is normative). [title] is "Top <Name>"; [aliases] are normalised phrases. */
data class GenreDef(val key: String, val title: String, val scope: GenreScope, val aliases: List<String>, val kids: Boolean, val tmdbMovie: List<Int>, val tmdbTV: List<Int>, val tmdbLang: String) {
    /** The genre's name: the title without "Top ". */
    val name: String get() = title.removePrefix("Top ")
    val shelfId: String get() = GenreShelves.PREFIX + key
}

/** The generated table (do not edit by hand: it is checked against smartmix/fixtures/genre-shelves.json by the tests). */
object GenreTable {
    val all: List<GenreDef> = listOf(
        GenreDef("action", "Top Action", GenreScope.BOTH, listOf("action", "action adventure"), false, listOf(28), listOf(10759), ""),
        GenreDef("comedy", "Top Comedy", GenreScope.BOTH, listOf("comedy", "comedies", "sitcom"), true, listOf(35), listOf(35), ""),
        GenreDef("drama", "Top Drama", GenreScope.BOTH, listOf("drama", "dramas"), false, listOf(18), listOf(18), ""),
        GenreDef("thriller", "Top Thriller", GenreScope.BOTH, listOf("thriller", "thrillers", "suspense"), false, listOf(53), listOf(), ""),
        GenreDef("scifi", "Top Science Fiction", GenreScope.BOTH, listOf("science fiction", "sci fi", "scifi", "sci fi fantasy"), false, listOf(878), listOf(10765), ""),
        GenreDef("horror", "Top Horror", GenreScope.BOTH, listOf("horror"), false, listOf(27), listOf(), ""),
        GenreDef("romance", "Top Romance", GenreScope.BOTH, listOf("romance", "romantic", "romcom"), false, listOf(10749), listOf(), ""),
        GenreDef("crime", "Top Crime", GenreScope.BOTH, listOf("crime", "gangster"), false, listOf(80), listOf(80), ""),
        GenreDef("animation", "Top Animation", GenreScope.BOTH, listOf("animation", "animated", "cartoon"), true, listOf(16), listOf(16), ""),
        GenreDef("documentary", "Top Documentary", GenreScope.BOTH, listOf("documentary", "documentaries", "docuseries"), false, listOf(99), listOf(99), ""),
        GenreDef("family", "Top Family", GenreScope.BOTH, listOf("family"), true, listOf(10751), listOf(10751), ""),
        GenreDef("fantasy", "Top Fantasy", GenreScope.BOTH, listOf("fantasy", "sci fi fantasy"), true, listOf(14), listOf(10765), ""),
        GenreDef("mystery", "Top Mystery", GenreScope.BOTH, listOf("mystery", "whodunit"), false, listOf(9648), listOf(9648), ""),
        GenreDef("adventure", "Top Adventure", GenreScope.BOTH, listOf("adventure", "action adventure"), true, listOf(12), listOf(10759), ""),
        GenreDef("war", "Top War", GenreScope.BOTH, listOf("war", "war politics", "military"), false, listOf(10752), listOf(10768), ""),
        GenreDef("western", "Top Western", GenreScope.BOTH, listOf("western"), false, listOf(37), listOf(37), ""),
        GenreDef("history", "Top History", GenreScope.BOTH, listOf("history", "historical"), false, listOf(36), listOf(), ""),
        GenreDef("music", "Top Music", GenreScope.BOTH, listOf("music", "musical", "concert"), true, listOf(10402), listOf(), ""),
        GenreDef("biography", "Top Biography", GenreScope.BOTH, listOf("biography", "biographical", "biopic"), false, listOf(), listOf(), ""),
        GenreDef("kids", "Top Kids", GenreScope.BOTH, listOf("kids", "children", "childrens"), true, listOf(), listOf(10762), ""),
        GenreDef("anime", "Top Anime", GenreScope.BOTH, listOf("anime"), false, listOf(16), listOf(16), "ja"),
        GenreDef("reality", "Top Reality", GenreScope.SERIES, listOf("reality", "reality tv"), false, listOf(), listOf(10764), ""),
    )
    private val byKey = all.associateBy { it.key }
    fun of(key: String): GenreDef? = byKey[key]
    fun ofShelf(shelfId: String): GenreDef? = if (shelfId.startsWith(GenreShelves.PREFIX)) byKey[shelfId.substring(GenreShelves.PREFIX.length)] else null
}
