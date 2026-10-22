package app.streamsetu.core.model

/**
 * A guide channel id as it is stored. Two playlists can use the same guide id for different channels, so the id is stored together with the playlist whose guide it came from.
 * A guide stored before this was done holds the bare id; it is still read, and is replaced as the guide is refreshed.
 */
object EpgIds {
    private const val SEP = '\u0001'

    fun scope(sourceId: String, id: String): String = "$sourceId$SEP$id"

    /** The id as the playlist wrote it. */
    fun raw(stored: String): String = stored.substringAfter(SEP)

    /** The playlist a stored id came from, or null for one stored before ids were scoped. */
    fun source(stored: String): String? = if (SEP in stored) stored.substringBefore(SEP) else null
}
