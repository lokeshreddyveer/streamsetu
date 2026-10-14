package app.streamsetu.core.playback

/** Turns what the catalog stores for a channel, movie or episode into the address the player opens. Implemented by the data layer. */
interface StreamUrlResolver {
    suspend fun resolve(sourceId: String, streamRef: String): String?
    /** A custom User-Agent the connection asks to be played with, if any. */
    suspend fun userAgent(sourceId: String): String? = null
    /** Request headers the connection needs for its streams (a login for a receiver or share, and any the person added). */
    suspend fun headers(sourceId: String): Map<String, String> = emptyMap()
}
