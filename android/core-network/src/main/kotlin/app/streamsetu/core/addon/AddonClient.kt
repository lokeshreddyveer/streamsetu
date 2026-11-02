package app.streamsetu.core.addon

import app.streamsetu.core.net.Http
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okio.BufferedSource
import java.util.concurrent.TimeUnit

/** An add-on's server could not be used. The message is written for the person who installed it. */
class AddonException(message: String) : Exception(message)

/**
 * Asks an add-on's server a question, under the add-on's own rules and nobody else's:
 *  - only https, only the servers the add-on named (checked again at every redirect, and a redirect to anywhere else ends the call);
 *  - at most [MAX_HOPS] redirects, the time limit and the size limit from the manifest, a JSON answer only;
 *  - the add-on's credential is attached to a request for one of its own servers and to nothing else; no other header can be set by an add-on.
 * Names are looked up through the app's own resolver (App DNS) and may only resolve to public addresses. The proxy chosen in Settings is deliberately NOT used for add-ons: a proxy would
 * resolve the name itself and the public-address check could not hold.
 */
open class AddonClient(private val base: () -> OkHttpClient = { Http.client }) {
    /**
     * The shared client for one add-on call: redirects are followed by hand, names may only resolve to public addresses, and the Settings proxy is not used: through a proxy the app would
     * hand the proxy a name and never see the address it reaches, so the public-address check could not hold. App DNS still applies.
     */
    internal fun callClient(timeoutSeconds: Long): OkHttpClient = base().let { b -> b.newBuilder().proxy(java.net.Proxy.NO_PROXY).dns(PublicOnlyDns(b.dns)).followRedirects(false).followSslRedirects(false).callTimeout(timeoutSeconds, TimeUnit.SECONDS).build() }


    /** The answer of the add-on's [capability] endpoint, as text, or the reason there is none. [query] is added to the address (encoded); [authorization] is the whole Authorization value, or null. */
    fun get(manifest: AddonManifest, capability: AddonCapability, query: Map<String, String> = emptyMap(), authorization: String? = null): String {
        val endpoint = manifest.endpoint(capability) ?: throw AddonException("${manifest.name} does not provide ${capability.key}.")
        return fetch(manifest, endpoint, query, authorization)
    }

    /** Reads an add-on description from an address a person typed. Not an add-on's own call: no credential is sent and no add-on host list applies; it must still be https and small. */
    open fun fetchManifest(url: String): String {
        val host = AddonManifestParser.hostOf(url) ?: throw AddonException("The address must start with https://.")
        if (AddonManifestParser.isPrivate(host)) throw AddonException("That address is on a private network. An add-on description must come from a public server.")
        val client = callClient(FETCH_SECONDS)
        var current = url.trim()
        repeat(MAX_HOPS + 1) {
            val u = current.toHttpUrlOrNull() ?: throw AddonException("That address is not valid.")
            if (u.scheme != "https" || AddonManifestParser.isPrivate(u.host)) throw AddonException("The server sent the app somewhere that is not allowed.")
            client.newCall(Request.Builder().url(u).header("Accept", "application/json").build()).execute().use { r ->
                if (r.isRedirect) { current = r.header("Location")?.let { u.resolve(it)?.toString() } ?: throw AddonException("The server's redirect had no address."); return@repeat }
                if (!r.isSuccessful) throw AddonException("The server answered ${r.code}.")
                return readLimited(r.body?.source() ?: throw AddonException("The server sent nothing."), r.body?.contentLength() ?: -1, AddonManifestParser.MAX_MANIFEST_BYTES.toLong())
            }
        }
        throw AddonException("Too many redirects.")
    }

    private fun fetch(manifest: AddonManifest, endpoint: String, query: Map<String, String>, authorization: String?): String {
        val allowed = manifest.allowedHosts.map { it.trim().lowercase() }.toSet()
        val client = callClient(manifest.limits.timeoutSeconds.toLong())
        var url = endpoint.toHttpUrlOrNull() ?: throw AddonException("${manifest.name} has an address that is not valid.")
        if (query.isNotEmpty()) url = url.newBuilder().apply { query.forEach { (k, v) -> addQueryParameter(k, v) } }.build()
        var hop = 0
        while (true) {
            val problem = checkHop(url.toString(), allowed)
            if (problem != null) throw AddonException("${manifest.name}: $problem")
            val request = Request.Builder().url(url).header("Accept", "application/json").apply { if (authorization != null) header("Authorization", authorization) }.build()
            client.newCall(request).execute().use { r ->
                if (r.isRedirect) {
                    if (++hop > MAX_HOPS) throw AddonException("${manifest.name} sent the app around too many times.")
                    url = r.header("Location")?.let { url.resolve(it) } ?: throw AddonException("${manifest.name} sent a redirect with no address.")
                    return@use
                }
                if (!r.isSuccessful) throw AddonException("${manifest.name}'s server answered ${r.code}.")
                val type = r.header("Content-Type").orEmpty().lowercase()
                if ("json" !in type) throw AddonException("${manifest.name} did not answer with JSON.")
                return readLimited(r.body?.source() ?: throw AddonException("${manifest.name} sent nothing."), r.body?.contentLength() ?: -1, manifest.limits.maxResponseBytes)
            }
        }
    }

    companion object {
        const val MAX_HOPS = 3
        /** A description or a list from a typed address: short, so an unreachable server is given up on quickly. */
        const val FETCH_SECONDS = 8L

        /** Null when a call to [url] is allowed, otherwise the reason it is not. */
        fun checkHop(url: String, allowedHosts: Set<String>): String? {
            val host = AddonManifestParser.hostOf(url) ?: return "the address is not a secure web address (https)."
            if (host !in allowedHosts) return "it was sent to “$host”, which it did not name."
            return null
        }

        /** Reads at most [max] bytes as text and refuses a bigger answer, without ever holding more than [max] + 1 bytes. */
        fun readLimited(source: BufferedSource, declared: Long, max: Long): String {
            if (declared > max) throw AddonException("The answer is larger than the add-on's size limit.")
            source.request(max + 1)
            if (source.buffer.size > max) throw AddonException("The answer is larger than the add-on's size limit.")
            return source.readUtf8()
        }
    }
}
