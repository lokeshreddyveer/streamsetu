package app.streamsetu.core.addon

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** Who vouches for an add-on. Shown next to its name; it changes what the person is warned about, never what the add-on is allowed to do. */
enum class AddonTrust(val label: String) { OFFICIAL("Official"), COMMUNITY("Community"), LOCAL("Local") }

/** What an add-on may supply. An endpoint is accepted only for a capability the add-on declares. */
enum class AddonCapability(val key: String) { CATALOG("catalog"), EPG("epg"), STREAM("stream");
    companion object { fun of(key: String) = entries.firstOrNull { it.key == key } }
}

/** How the person signs in to the add-on's service. The secret itself is kept in the credential store and is only ever sent to the add-on's own allowed hosts. */
enum class AddonAuth(val key: String) { NONE("none"), USERNAME_PASSWORD("usernamePassword"), TOKEN("token");
    companion object { fun of(key: String) = entries.firstOrNull { it.key == key } }
}

@Serializable data class AddonAuthentication(val type: String = "none")
@Serializable data class AddonLimits(val timeoutSeconds: Int = 10, val maxResponseBytes: Long = 10L * 1024 * 1024)

/**
 * A connection add-on is a description, never code: where to ask, for what, on which hosts, and with what limits. Nothing in it is executed; the app reads the answers itself.
 * Fields that are not part of the format are refused, so a manifest cannot carry anything the app does not look at.
 */
@Serializable
data class AddonManifest(
    val schema: Int,
    val id: String,
    val name: String,
    val capabilities: List<String>,
    val authentication: AddonAuthentication = AddonAuthentication(),
    val endpoints: Map<String, String>,
    @SerialName("allowedHosts") val allowedHosts: List<String>,
    val limits: AddonLimits = AddonLimits(),
) {
    val capabilitySet: Set<AddonCapability> get() = capabilities.mapNotNull { AddonCapability.of(it) }.toSet()
    val auth: AddonAuth get() = AddonAuth.of(authentication.type) ?: AddonAuth.NONE
    fun endpoint(c: AddonCapability): String? = endpoints[c.key]
}

sealed class ManifestResult {
    data class Valid(val manifest: AddonManifest) : ManifestResult()
    /** Every reason the manifest was refused, each in a sentence a person can read. */
    data class Refused(val reasons: List<String>) : ManifestResult()
}

/** Reads and checks a manifest before anything about it is stored. A manifest that does not pass is never installed. */
object AddonManifestParser {
    const val MAX_MANIFEST_BYTES = 64 * 1024
    const val MIN_RESPONSE_BYTES = 1024L
    const val MAX_RESPONSE_BYTES = 32L * 1024 * 1024
    const val MAX_TIMEOUT_SECONDS = 30
    private val idPattern = Regex("^[a-z0-9][a-z0-9._-]{2,63}$")
    private val hostPattern = Regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$")
    private val strict = Json { ignoreUnknownKeys = false; isLenient = false }

    fun parse(text: String): ManifestResult {
        if (text.toByteArray().size > MAX_MANIFEST_BYTES) return ManifestResult.Refused(listOf("The add-on description is larger than ${MAX_MANIFEST_BYTES / 1024} KB."))
        val m = try { strict.decodeFromString(AddonManifest.serializer(), text) } catch (e: Exception) {
            return ManifestResult.Refused(listOf("This is not an add-on description this version of StreamSetu understands."))
        }
        val problems = validate(m)
        return if (problems.isEmpty()) ManifestResult.Valid(m) else ManifestResult.Refused(problems)
    }

    fun validate(m: AddonManifest): List<String> {
        val out = ArrayList<String>()
        if (m.schema != 1) out += "Only add-on format 1 is supported (this one says ${m.schema})."
        if (!idPattern.matches(m.id)) out += "The add-on's id must be 3 to 64 lowercase letters, digits, dots, dashes or underscores."
        if (m.name.isBlank() || m.name.length > 60) out += "The add-on's name must be 1 to 60 characters."
        if (m.capabilities.isEmpty()) out += "The add-on does not say what it provides."
        m.capabilities.filter { AddonCapability.of(it) == null }.forEach { out += "“$it” is not something an add-on can provide." }
        if (m.capabilities.toSet().size != m.capabilities.size) out += "A capability is listed twice."
        if (AddonAuth.of(m.authentication.type) == null) out += "“${m.authentication.type}” is not a way of signing in that is supported."

        val hosts = m.allowedHosts.map { it.trim().lowercase() }
        if (hosts.isEmpty()) out += "The add-on does not name the servers it may talk to."
        if (hosts.size > 20) out += "The add-on names more than 20 servers."
        hosts.forEach { h ->
            when {
                !hostPattern.matches(h) -> out += "“$h” is not a server name (no addresses, ports, paths or wildcards)."
                isPrivate(h) -> out += "“$h” is on a private network. An add-on may only talk to public servers."
            }
        }

        val declared = m.capabilitySet
        m.endpoints.forEach { (key, url) ->
            val cap = AddonCapability.of(key)
            if (cap == null) { out += "“$key” is not an endpoint an add-on can have."; return@forEach }
            if (cap !in declared) out += "The add-on has a $key endpoint but does not declare that it provides $key."
            val host = hostOf(url)
            when {
                host == null -> out += "The $key address is not a secure web address (https)."
                host !in hosts -> out += "The $key address is on “$host”, which is not in the add-on's list of servers."
            }
        }
        declared.filter { it.key !in m.endpoints.keys }.forEach { out += "The add-on declares ${it.key} but has no ${it.key} address." }

        if (m.limits.timeoutSeconds !in 1..MAX_TIMEOUT_SECONDS) out += "The time limit must be 1 to $MAX_TIMEOUT_SECONDS seconds."
        if (m.limits.maxResponseBytes !in MIN_RESPONSE_BYTES..MAX_RESPONSE_BYTES) out += "The size limit must be between ${MIN_RESPONSE_BYTES / 1024} KB and ${MAX_RESPONSE_BYTES / (1024 * 1024)} MB."
        return out
    }

    /** The host of an https address, lower case, or null when it is not one (a different scheme, a user name in the address, a missing host). */
    fun hostOf(url: String): String? {
        val u = url.trim()
        if (!u.startsWith("https://", ignoreCase = true)) return null
        val rest = u.substring(8)
        val authority = rest.substringBefore('/').substringBefore('?').substringBefore('#')
        if (authority.isEmpty() || '@' in authority) return null
        val host = authority.substringBefore(':').lowercase()
        if (authority.contains(':') && authority.substringAfter(':').toIntOrNull() !in 1..65535) return null
        return host.takeIf { hostPattern.matches(it) }
    }

    /** Private, loopback and link-local names and addresses: an add-on is never a way to reach something inside the person's own network. */
    private val ipv4Literal = Regex("^\\d{1,3}(\\.\\d{1,3}){3}$")

    fun isPrivate(host: String): Boolean {
        val h = host.lowercase()
        // An address written out is never looked up by name, so the resolver check cannot see it: it is judged here, by the same table the resolver uses.
        if (ipv4Literal.matches(h)) return !runCatching { AddonAddresses.isPublic(java.net.InetAddress.getByName(h)) }.getOrDefault(false)
        return h == "localhost" || h.endsWith(".local") || h.endsWith(".localhost") || h.endsWith(".internal") || h.endsWith(".lan") || h.endsWith(".home") ||
            Regex("^(10\\.|192\\.168\\.|172\\.(1[6-9]|2\\d|3[01])\\.|127\\.|169\\.254\\.|0\\.)").containsMatchIn(h) || ':' in h
    }
}
