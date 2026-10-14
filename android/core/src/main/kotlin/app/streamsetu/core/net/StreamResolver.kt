package app.streamsetu.core.net

import app.streamsetu.core.data.repo.SourceRepository
import app.streamsetu.core.model.SourceType
import app.streamsetu.core.parse.Xtream
import app.streamsetu.core.security.CredentialStore

/** Turns the reference stored with a channel, movie or episode into the address the player opens. */
class StreamResolver(private val sources: SourceRepository, private val credentials: CredentialStore) {
    suspend fun resolve(sourceId: String, streamRef: String): String? {
        if (streamRef.startsWith("http://") || streamRef.startsWith("https://") || streamRef.startsWith("rtmp") || streamRef.startsWith("rtsp")) return streamRef
        val s = sources.get(sourceId) ?: return null
        if (s.type != SourceType.XTREAM) return null
        val pass = credentials.load(SourceRepository.credentialRef(s.id)) ?: return null
        return Xtream.streamUrl(s.address, s.username.orEmpty(), pass, streamRef)
    }
}
