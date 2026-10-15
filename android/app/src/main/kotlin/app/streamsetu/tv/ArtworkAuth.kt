package app.streamsetu.tv

import app.streamsetu.core.data.repo.SourceRepository
import app.streamsetu.core.model.SourceType
import app.streamsetu.core.security.CredentialStore
import kotlinx.coroutines.runBlocking
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Interceptor
import okhttp3.Response

/**
 * Pictures on a Plex server need its access token. The token goes on the request as a header, only for that server, so it is never part of an address that is
 * saved in the catalog, shown, exported or logged.
 */
class ArtworkAuth(private val sources: SourceRepository, private val credentials: CredentialStore) : Interceptor {
    @Volatile private var tokens: Map<String, String> = emptyMap()
    @Volatile private var loadedAt = 0L

    private fun hostKey(address: String): String? {
        val url = (if ("://" in address) address else "http://$address").toHttpUrlOrNull() ?: return null
        return "${url.host}:${url.port}"
    }

    private fun load(): Map<String, String> {
        val now = System.currentTimeMillis()
        if (now - loadedAt > 30_000) {
            tokens = runCatching {
                runBlocking { sources.all() }.filter { it.type == SourceType.PLEX && !it.draft }.mapNotNull { s ->
                    val key = hostKey(s.address) ?: return@mapNotNull null
                    val token = credentials.load(SourceRepository.credentialRef(s.id))?.takeIf { it.isNotBlank() } ?: return@mapNotNull null
                    key to token
                }.toMap()
            }.getOrDefault(tokens)
            loadedAt = now
        }
        return tokens
    }

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val token = load()["${request.url.host}:${request.url.port}"]
        return chain.proceed(if (token != null && request.header("X-Plex-Token") == null) request.newBuilder().header("X-Plex-Token", token).build() else request)
    }
}
