package app.streamsetu.core.model

/** What a playlist entry is. */
enum class ContentKind { CHANNEL, MOVIE, SERIES, EPISODE }

enum class SourceType { M3U, XTREAM }

/** A playlist the person added. The password is never part of this class; it lives in the [app.streamsetu.core.security.CredentialStore]. */
data class Source(
    val id: String,
    val name: String,
    val type: SourceType,
    /** The playlist address (M3U) or the server address (Xtream). */
    val address: String,
    val username: String? = null,
    val epgUrl: String? = null,
    val enabled: Boolean = true,
    val lastSyncAt: Long = 0,
    val status: SyncStatus = SyncStatus.NEVER,
)

enum class SyncStatus { NEVER, SYNCING, OK, FAILED }

data class Category(
    val id: String,
    val sourceId: String,
    val kind: ContentKind,
    val name: String,
    val sortOrder: Int = 0,
)

data class Channel(
    val id: String,
    val sourceId: String,
    val categoryId: String?,
    val name: String,
    val number: Int?,
    val logoUrl: String?,
    /** A full address (M3U) or a reference the [app.streamsetu.core.net.StreamResolver] turns into one (Xtream). */
    val streamRef: String,
    val epgId: String?,
    val catchupDays: Int = 0,
)

data class Movie(
    val id: String,
    val sourceId: String,
    val categoryId: String?,
    val title: String,
    val posterUrl: String?,
    val year: Int?,
    val rating: String?,
    val plot: String?,
    val streamRef: String,
    val addedAt: Long = 0,
)

data class Series(
    val id: String,
    val sourceId: String,
    val categoryId: String?,
    val title: String,
    val posterUrl: String?,
    val backdropUrl: String?,
    val year: Int?,
    val rating: String?,
    val plot: String?,
    val providerId: String,
)

data class Episode(
    val id: String,
    val seriesId: String,
    val season: Int,
    val number: Int,
    val title: String,
    val plot: String?,
    val imageUrl: String?,
    val durationSec: Int?,
    val streamRef: String,
)

data class EpgProgram(
    val channelEpgId: String,
    val startMs: Long,
    val endMs: Long,
    val title: String,
    val description: String?,
) {
    fun isLive(nowMs: Long) = nowMs in startMs until endMs
}

data class WatchProgress(
    val itemId: String,
    val kind: ContentKind,
    val seriesId: String?,
    val positionMs: Long,
    val durationMs: Long,
    val updatedAt: Long,
    val completed: Boolean,
) {
    val fraction: Float get() = if (durationMs > 0) (positionMs.toFloat() / durationMs).coerceIn(0f, 1f) else 0f
}

/** Something that can be put on screen and played. */
sealed interface Playable {
    val id: String
    val title: String
    val sourceId: String
    val streamRef: String
    val isLive: Boolean
    val artworkUrl: String?
}

data class ChannelPlayable(val channel: Channel) : Playable {
    override val id get() = channel.id
    override val title get() = channel.name
    override val sourceId get() = channel.sourceId
    override val streamRef get() = channel.streamRef
    override val isLive get() = true
    override val artworkUrl get() = channel.logoUrl
}

data class MoviePlayable(val movie: Movie) : Playable {
    override val id get() = movie.id
    override val title get() = movie.title
    override val sourceId get() = movie.sourceId
    override val streamRef get() = movie.streamRef
    override val isLive get() = false
    override val artworkUrl get() = movie.posterUrl
}

data class EpisodePlayable(val episode: Episode, val series: Series) : Playable {
    override val id get() = episode.id
    override val title get() = "${series.title}  S${episode.season} E${episode.number}"
    override val sourceId get() = series.sourceId
    override val streamRef get() = episode.streamRef
    override val isLive get() = false
    override val artworkUrl get() = episode.imageUrl ?: series.posterUrl
}
