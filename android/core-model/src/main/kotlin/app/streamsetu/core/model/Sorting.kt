package app.streamsetu.core.model

/** What a list can be ordered by. A field is offered only when the catalog really carries that information. */
enum class SortField(val label: String) {
    PROVIDER("Provider order"), NAME("Name"), ADDED("Recently added"), UPDATED("Recently updated"), NEW_EPISODES("New episodes first"), RECENTLY_WATCHED("Recently watched"), YEAR("Release year"), RATING("Rating"), DURATION("Duration")
}

/**
 * How a list is ordered. [favoritesFirst] and [unwatchedFirst] are applied before the main field. Ties always break by a stable id,
 * so items in a combined library do not jump around between refreshes.
 */
data class SortSpec(val field: SortField = SortField.PROVIDER, val ascending: Boolean = true, val favoritesFirst: Boolean = false, val unwatchedFirst: Boolean = false) {
    val isDefault get() = this == SortSpec()
    fun encode() = "${field.name}|$ascending|$favoritesFirst|$unwatchedFirst"
    companion object {
        /** What a list is ordered by until the person chooses otherwise: most recently added first, everywhere. All the other orders stay available. */
        @Suppress("UNUSED_PARAMETER") fun defaultFor(kind: ContentKind) = SortSpec(SortField.ADDED)

        fun decode(s: String?): SortSpec {
            val p = s?.split('|') ?: return SortSpec()
            if (p.size != 4) return SortSpec()
            return SortSpec(SortField.entries.firstOrNull { it.name == p[0] } ?: SortField.PROVIDER, p[1].toBoolean(), p[2].toBoolean(), p[3].toBoolean())
        }
    }
}

/** Which sort fields the open library can honestly offer, from what the catalog holds. */
data class SortAvailability(val year: Boolean, val rating: Boolean, val duration: Boolean, val recentlyWatched: Boolean, val seriesUpdated: Boolean = false, val newEpisodes: Boolean = false) {
    fun offers(kind: ContentKind): List<SortField> = buildList {
        add(SortField.PROVIDER); add(SortField.NAME); add(SortField.ADDED)
        if (recentlyWatched) add(SortField.RECENTLY_WATCHED)
        if (kind != ContentKind.CHANNEL) { if (year) add(SortField.YEAR); if (rating) add(SortField.RATING) }
        if (kind == ContentKind.MOVIE && duration) add(SortField.DURATION)
        if (kind == ContentKind.SERIES && seriesUpdated) add(SortField.UPDATED)
        if (kind == ContentKind.SERIES && newEpisodes) add(SortField.NEW_EPISODES)
    }
}

/** The shortcut entries at the top of a folder panel, plus a provider folder. */
sealed interface Browse {
    data object All : Browse
    data object Favorites : Browse
    data object WatchLater : Browse
    data object Continue : Browse
    data object Recent : Browse
    data object RecentlyAdded : Browse
    data class Folder(val id: String) : Browse
    /** The person's starred folders, shown together. */
    data object FavoriteFolders : Browse
    data class Collection(val id: String) : Browse
    data class Smart(val rule: SmartRule) : Browse
}

/**
 * What a connection can really do, found from what it delivered (never assumed from its type). The screens switch features on only when they are true.
 * Seek, audio tracks and adaptive quality belong to a single stream and are reported by the player while it plays.
 */
data class SourceCapabilities(val guide: Boolean, val guideChannels: Int, val catchUp: Boolean, val catchUpChannels: Int, val movies: Boolean, val series: Boolean, val live: Boolean)

/** Built-in rules that fill a list by themselves from what the library and the person's history say. No cloud, no guessing. */
enum class SmartRule(val label: String) { UNWATCHED("Unwatched"), UNWATCHED_FAVORITES("Unwatched favorites"), NEW_30D("Added in the last 30 days") }

data class UserCollection(val id: String, val name: String, val scope: ContentKind)
data class ItemOverride(val title: String?, val posterUrl: String?)
