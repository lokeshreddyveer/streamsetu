package app.streamsetu.core.playback

/** Turns what the catalog stores for a channel, movie or episode into the address the player opens. Implemented by the data layer. */
fun interface StreamUrlResolver {
    suspend fun resolve(sourceId: String, streamRef: String): String?
}
