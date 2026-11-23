package app.streamsetu.core.data.smartmix

enum class Kind { MOVIE, SERIES }

/**
 * One library copy (a "member" of an identity group). The engine groups members by (kind, identityKey, year cluster), picks the
 * representative and aggregates restriction/watch/play signals over the whole group (see [IdentityGrouping]). Slim on purpose: no title, no URL, no plot.
 */
data class Candidate(
    val id: String,
    val kind: Kind = Kind.MOVIE,
    val identityKey: String = "",
    val year: Int? = null,
    /** Days before the day start the item was added (<0 is treated as 0); null when the provider only gives list positions. */
    val addedDays: Int? = null,
    val ratingText: String? = null,
    /** 0 CAM/TS, 1 SD, 2 unmarked, 3 HD, 4 FHD, 5 4K. */
    val qualityRank: Int = 2,
    val isCam: Boolean = false,
    val lang: String? = null,
    val folderKey: String? = null,
    val franchiseKey: String? = null,
    val primaryGenre: String? = null,
    val hasPoster: Boolean = true,
    val hasBackdrop: Boolean = false,
    val watched: Boolean = false,
    /** Fully watched (as opposed to partially). */
    val completed: Boolean = false,
    /** Days since last watched; null when unknown. */
    val lastWatchedDays: Int? = null,
    val plays7: Int = 0,
    val plays30: Int = 0,
    /** 1-based TMDB weekly rank when matched locally, else null. */
    val trendingRank: Int? = null,
    /** Loads since it was last shown on this shelf; null = never / not recorded. */
    val loadsAgo: Int? = null,
    /** Locked, hidden, hide-adult/Kids: such a member removes its whole identity group from recommendations. */
    val restricted: Boolean = false,
    /** "Remove from Continue Watching" marker (recommendations only). */
    val dismissed: Boolean = false,
    /** Source preference rank (lower wins). */
    val sourceRank: Int = 0,
    /** Set on a group representative: every member is CAM/TS. */
    val camOnly: Boolean = false,
    /** The provider's genre text as normalised tokens (see [GenreShelves.tokens]); empty when the title has none. */
    val genres: List<String> = emptyList(),
)

data class Affinity(
    val topLangs: List<String> = emptyList(),
    val topFolders: List<String> = emptyList(),
    val topGenres: List<String> = emptyList(),
    val topDecades: List<Int> = emptyList(),
) {
    companion object { val NONE = Affinity() }
}

data class Context(
    val profileId: String,
    val dayKey: String,
    val refreshCounter: Int = 0,
    val nowYear: Int = dayKey.substring(0, 4).toInt(),
    val preferredLang: String? = null,
    val affinity: Affinity = Affinity.NONE,
    /** Test/low-end override of the candidate pool cap. */
    val poolCap: Int? = null,
    /** Extra picks drawn after the normal ones (Home uses 10, fixtures 0); the first `size` picks are the same with and without. */
    val oversample: Int = 0,
    /** A Kids profile: moods draw from kid-safe genres only. */
    val kids: Boolean = false,
    /** Showable titles in the pool: a mood needs at least [HomeMoods.floor] matching titles (0 = the plain minimum of 8). */
    val libraryTotal: Int = 0,
)

/** Counts only: never a title, id or address. Field names are the shared fixture names. */
data class ShelfDiagnostics(
    val inCount: Int = 0,
    val groups: Int = 0,
    val restricted: Int = 0,
    val dismissed: Int = 0,
    val camOnly: Int = 0,
    val noArtwork: Int = 0,
    val watched: Int = 0,
    val lang: Int = 0,
    val notTrending: Int = 0,
    val pool: Int = 0,
    val drawn: Int = 0,
    /** Highest relaxation tier used (0..5, see [Relax]). */
    val tier: Int = 0,
    val tiny: Boolean = false,
    val hidden: Boolean = false,
    /** none | recentlyAdded | plainLibrary | existingFeatured */
    val fallback: String = "none",
    val diversityRelaxed: Boolean = false,
    val caption: String = "",
    val tmdb: String = "",
    val trendMode: Boolean = false,
)

data class ShelfResult(val shelfId: String, val ids: List<String>, val art: List<String>, val diagnostics: ShelfDiagnostics) {
    val hidden: Boolean get() = diagnostics.hidden
}

object Relax {
    const val FRESH = 1
    const val DIVERSITY = 2
    const val WATCHED = 3
    const val ARTWORK = 4
    const val CAM = 5
}

/** Weights in percent, order: release, added, quality, language, rating, popularity, affinity, fresh (sum 100). */
class Weights(val release: Int, val added: Int, val quality: Int, val language: Int, val rating: Int, val popularity: Int, val affinity: Int, val fresh: Int) {
    init { require(release + added + quality + language + rating + popularity + affinity + fresh == 100) { "weights must sum to 100" } }
}

data class ShelfSpec(
    val id: String,
    val weights: Weights,
    val sharp: Boolean,
    val pool: Int,
    val size: Int,
    val minCount: Int,
    val mixesKinds: Boolean = false,
    val folderKey: String? = null,
    val genre: GenreDef? = null,
    /** Mood rows: the union of genre keys (see [HomeMoods]). */
    val moodKeys: List<String>? = null,
) {
    val isFolder get() = folderKey != null
    /** Rows of Home v2 that are built like genre rows and have no fallback: below the minimum, or only at tier 4 or 5, they are hidden. */
    val isContextRow get() = id == FRESH || id == MOVIE_NIGHT || id == BINGE || moodKeys != null
    /** The same shelf with other weights (the all-time view of Trending in Your Library when nothing matched). */
    fun withWeights(w: Weights) = ShelfSpec(id, w, sharp, pool, size, minCount, mixesKinds, folderKey, genre, moodKeys)

    companion object {
        const val HERO = "hero"
        const val FOR_YOU = "for-you"
        const val REDISCOVER = "rediscover"
        const val LANG_PREF = "lang-pref"
        const val TOP_WEEK = "top-week"
        const val TRENDING_LIBRARY = "trending-library"
        const val TRENDING_MIN_MATCHES = 6
        const val FRESH = "fresh"
        const val MOVIE_NIGHT = "movie-night"
        const val BINGE = "binge"
        /** Not an engine shelf: the collections row is built by [HomeCollections]. */
        const val COLLECTIONS = "collections"
        /** Days a title counts as freshly added. */
        const val FRESH_DAYS = 14
        /** Context rows are hidden below this many titles. */
        const val CONTEXT_MIN = 6

        val GLOBAL = listOf(HERO, FOR_YOU, REDISCOVER, LANG_PREF, TOP_WEEK, TRENDING_LIBRARY)

        val CONTEXT = listOf(FRESH, MOVIE_NIGHT, BINGE)

        fun of(shelfId: String, view: ShelfView = ShelfView.WEEKLY, kids: Boolean = false): ShelfSpec = when {
            shelfId == COLLECTIONS -> ShelfSpec(shelfId, Weights(10, 15, 10, 10, 5, 40, 0, 10), true, 2000, 14, 6)
            shelfId == FRESH -> ShelfSpec(shelfId, Weights(0, 50, 10, 5, 10, 15, 0, 10), true, 2000, 14, CONTEXT_MIN, mixesKinds = true)
            shelfId == MOVIE_NIGHT -> ShelfSpec(shelfId, Weights(10, 0, 20, 10, 35, 15, 0, 10), true, 2000, 14, CONTEXT_MIN)
            shelfId == BINGE -> ShelfSpec(shelfId, Weights(5, 5, 10, 10, 35, 25, 0, 10), true, 2000, 14, CONTEXT_MIN)
            HomeMoods.of(shelfId) != null -> ShelfSpec(shelfId, GenreShelves.WEEKLY_WEIGHTS, true, 2000, 14, CONTEXT_MIN, mixesKinds = true, moodKeys = HomeMoods.genreKeys(HomeMoods.of(shelfId)!!, kids))
            GenreTable.ofShelf(shelfId) != null -> ShelfSpec(shelfId, if (view == ShelfView.ALL_TIME) GenreShelves.ALL_TIME_WEIGHTS else GenreShelves.WEEKLY_WEIGHTS, true, 2000, GenreShelves.SHELF_SIZE, GenreShelves.MIN_TITLES, mixesKinds = true, genre = GenreTable.ofShelf(shelfId))
            shelfId.startsWith("folder:") -> ShelfSpec(shelfId, Weights(10, 25, 30, 20, 0, 0, 0, 15), false, 200, 12, 1, folderKey = shelfId.substring(7))
            shelfId == HERO -> ShelfSpec(shelfId, Weights(10, 10, 15, 15, 5, 10, 20, 15), true, 2000, 12, 3, mixesKinds = true)
            shelfId == FOR_YOU -> ShelfSpec(shelfId, Weights(5, 5, 10, 15, 5, 10, 40, 10), true, 2000, 14, 6)
            shelfId == REDISCOVER -> ShelfSpec(shelfId, Weights(10, 0, 15, 15, 10, 0, 35, 15), true, 2000, 14, 6)
            shelfId == LANG_PREF -> ShelfSpec(shelfId, Weights(15, 15, 25, 0, 5, 15, 15, 10), true, 2000, 14, 6)
            shelfId == TOP_WEEK -> ShelfSpec(shelfId, Weights(10, 15, 10, 10, 5, 40, 0, 10), true, 2000, 14, 6)
            shelfId == TRENDING_LIBRARY -> ShelfSpec(shelfId, Weights(10, 15, 10, 10, 5, 40, 0, 10), true, 2000, 14, 3)
            else -> throw IllegalArgumentException("unknown shelf")
        }
    }
}
