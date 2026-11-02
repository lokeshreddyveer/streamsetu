package app.streamsetu.core.sync

import app.streamsetu.core.addon.AddonCatalog
import app.streamsetu.core.data.db.CategoryEntity
import app.streamsetu.core.data.db.ChannelEntity
import app.streamsetu.core.data.db.EpisodeEntity
import app.streamsetu.core.data.db.MovieEntity
import app.streamsetu.core.data.db.SeriesEntity

/** What an add-on's catalog becomes in the database. Titles and channels play the address the add-on gave; without one they are asked for when played (see AddonRegistry.resolveStream). */
class AddonRows(val categories: List<CategoryEntity>, val channels: List<ChannelEntity>, val movies: List<MovieEntity>, val series: List<SeriesEntity> = emptyList(), val episodes: List<EpisodeEntity> = emptyList())

object AddonSync {
    /** The stream reference of something that has no address of its own: "addon:", what it is (c channel, m movie, e episode) and the add-on's own id for it. */
    const val LAZY_PREFIX = "addon:"
    fun lazyRef(kind: Char, id: String) = "$LAZY_PREFIX$kind:$id"
    /** The question to ask an add-on's stream endpoint for a lazy reference (without the prefix): what it is and its id. Null when the reference is not one. */
    fun lazyQuestion(ref: String): Map<String, String>? {
        val kind = when (ref.substringBefore(':', "")) { "c" -> "channel"; "m" -> "movie"; "e" -> "episode"; else -> return null }
        val id = ref.substringAfter(':', "").takeIf { it.isNotEmpty() } ?: return null
        return mapOf("kind" to kind, "id" to id)
    }

    fun toRows(sourceId: String, catalog: AddonCatalog, now: Long = System.currentTimeMillis()): AddonRows {
        val declared = catalog.categories.associateBy { it.id }
        fun categoryId(kind: String, id: String?) = id?.let { "$sourceId:cat:$kind:$it" }
        val categories = ArrayList<CategoryEntity>()
        fun add(kind: String, used: List<String>) = used.distinct().forEachIndexed { i, id -> categories += CategoryEntity(categoryId(kind, id)!!, sourceId, kind, declared[id]?.name ?: id, i) }
        add("CHANNEL", catalog.channels.mapNotNull { it.category })
        add("MOVIE", catalog.movies.mapNotNull { it.category })
        add("SERIES", catalog.series.mapNotNull { it.category })
        val channels = catalog.channels.mapIndexed { i, c ->
            ChannelEntity("$sourceId:c:${c.id}", sourceId, categoryId("CHANNEL", c.category), c.title, c.number, c.image, c.url ?: lazyRef('c', c.id), null, 0, i, now)
        }
        val movies = catalog.movies.mapIndexed { i, m ->
            MovieEntity("$sourceId:m:${m.id}", sourceId, categoryId("MOVIE", m.category), m.title, m.image, m.year, m.rating, m.plot, m.url ?: lazyRef('m', m.id), now - i)          // the add-on's own order is kept
        }
        val series = catalog.series.mapIndexed { i, s ->
            SeriesEntity("$sourceId:s:${s.id}", sourceId, categoryId("SERIES", s.category), s.title, s.image, null, s.year, s.rating, s.plot, s.id, now - i)
        }
        val episodes = catalog.series.flatMap { s ->
            s.episodes.map { e -> EpisodeEntity("$sourceId:e:${s.id}:${e.id}", "$sourceId:s:${s.id}", e.season, e.number, e.title.ifBlank { "Episode ${e.number}" }, e.plot, e.image, e.minutes?.times(60), e.url ?: lazyRef('e', e.id)) }
        }
        return AddonRows(categories, channels, movies, series, episodes)
    }
}
