package app.streamsetu.core.model

/** What a playlist entry is. */
enum class ContentKind { CHANNEL, MOVIE, SERIES, EPISODE }

enum class SourceType(val label: String) {
    M3U("M3U URL"), XTREAM("Xtream Codes"), LOCAL_FILE("Local M3U file"), STALKER("Stalker portal"),
    HDHOMERUN("HDHomeRun"), TVHEADEND("TVHeadend"), ENIGMA2("Enigma2 receiver"), JELLYFIN("Jellyfin"), EMBY("Emby"), PLEX("Plex"), WEBDAV("WebDAV"), LOCAL_FOLDER("Folder on this device");

    /** Needs a user name and password (Plex needs only a token, kept as the password). */
    val usesLogin: Boolean get() = this == XTREAM || this == TVHEADEND || this == ENIGMA2 || this == JELLYFIN || this == EMBY || this == PLEX || this == WEBDAV

    companion object { fun fromLabel(label: String): SourceType = entries.firstOrNull { it.label == label } ?: XTREAM }
}

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
    /** Saved before it was tested; not a working library. */
    val draft: Boolean = false,
    val channelCount: Int = 0,
    val movieCount: Int = 0,
    val seriesCount: Int = 0,
    val lastError: String? = null,
    val lastOpenedAt: Long = 0,
    /** Sent instead of the app's own name when this connection is read and played (some providers only answer a particular player). */
    val userAgent: String? = null,
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
    /** An audio-only station: played without a picture. */
    val isRadio: Boolean = false,
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
    /** False for things whose position must not be remembered (catch-up recordings). */
    val tracksProgress: Boolean get() = !isLive
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

/** A series shown in the banner. It is opened, not played, so it is not a stream. */
data class SeriesFeature(val series: Series) : Playable {
    override val id get() = series.id
    override val title get() = series.title
    override val sourceId get() = series.sourceId
    override val streamRef get() = ""
    override val isLive get() = false
    override val artworkUrl get() = series.backdropUrl ?: series.posterUrl
}

data class EpisodePlayable(val episode: Episode, val series: Series) : Playable {
    override val id get() = episode.id
    override val title get() = "${series.title}  S${episode.season} E${episode.number}"
    override val sourceId get() = series.sourceId
    override val streamRef get() = episode.streamRef
    override val isLive get() = false
    override val artworkUrl get() = episode.imageUrl ?: series.posterUrl
}

/** One row of the "Choose Your Library" screen. */
data class LibraryEntry(
    val id: String,
    val name: String,
    val kind: Kind,
    /** The connections this library reads (one for a connection, several for a combined library). */
    val sourceIds: List<String>,
    val typeLabel: String,
    val channelCount: Int,
    val movieCount: Int,
    val seriesCount: Int,
    val lastSyncAt: Long,
    val lastOpenedAt: Long,
    val health: Health,
) {
    enum class Kind { COMBINED, CONNECTION, UNFINISHED }
    enum class Health { OK, NEVER_READ, LAST_READ_FAILED, UNFINISHED }
    /** Only a connection that was tested and read at least once (or a combined library of those) opens Home. */
    val usable get() = kind != Kind.UNFINISHED && (channelCount + movieCount + seriesCount) > 0
}

/** The person's arrangement of a provider folder (see FolderPrefEntity). */
data class FolderPref(
    val favorite: Boolean = false, val pinned: Boolean = false, val hidden: Boolean = false, val locked: Boolean = false,
    val alias: String? = null, val sortIndex: Int = -1,
)

data class Folder(val id: String, val sourceId: String, val providerName: String, val count: Int, val pref: FolderPref = FolderPref()) {
    val title get() = pref.alias?.takeIf { it.isNotBlank() } ?: providerName
}

/** A programme that already aired, played from the provider's archive (catch-up). It is a recording: it can be paused and skipped, but no resume point is kept. */
data class CatchUpPlayable(val channel: Channel, val programTitle: String, val startMs: Long, val endMs: Long) : Playable {
    override val id get() = "catchup:${channel.id}:$startMs"
    override val title get() = "$programTitle  ·  ${channel.name}"
    override val sourceId get() = channel.sourceId
    override val streamRef get() = "timeshift:${channel.streamRef.split(':').getOrNull(1).orEmpty()}:$startMs:${((endMs - startMs) / 60_000L + 1).coerceAtLeast(1)}"
    override val isLive get() = false
    override val artworkUrl get() = channel.logoUrl
    override val tracksProgress get() = false
}
