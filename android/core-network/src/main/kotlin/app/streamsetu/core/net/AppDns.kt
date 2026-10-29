package app.streamsetu.core.net

import okhttp3.Cache
import okhttp3.Dns
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.dnsoverhttps.DnsOverHttps
import java.io.File
import java.net.InetAddress
import java.net.UnknownHostException

/**
 * App DNS: StreamSetu looks up server names through an encrypted (DNS-over-HTTPS) resolver the person chose, for its own traffic only. It is not a VPN and changes nothing outside the
 * app. The resolver sees host names and nothing else. With App DNS on there is no quiet fall-back to the device's DNS for remote names: a lookup that cannot be answered fails.
 * Names on the local network use the device's DNS when that is switched on. Used by the shared client, so playlists, guides, artwork, search, health checks and Media3 playback all follow it.
 */
object AppDns : Dns {
    enum class Provider(val label: String, val summary: String, val url: String?, val bootstrap: List<String>) {
        CLOUDFLARE("Cloudflare", "Fast, unfiltered DNS; recommended", "https://cloudflare-dns.com/dns-query", listOf("1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001")),
        GOOGLE("Google", "Fast, unfiltered DNS", "https://dns.google/dns-query", listOf("8.8.8.8", "8.8.4.4", "2001:4860:4860::8888", "2001:4860:4860::8844")),
        QUAD9("Quad9", "Blocks known malicious domains", "https://dns.quad9.net/dns-query", listOf("9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9")),
        ADGUARD("AdGuard", "Blocks ads and trackers; may block some IPTV hosts", "https://dns.adguard-dns.com/dns-query", listOf("94.140.14.14", "94.140.15.15", "2a10:50c0::ad1:ff", "2a10:50c0::ad2:ff")),
        CONTROL_D("Control D", "Unfiltered profile; filtering profiles are set up on controld.com", "https://freedns.controld.com/p0", listOf("76.76.2.0", "76.76.10.0")),
        CUSTOM("Custom", "Your own or a third-party DoH resolver", null, emptyList());
        companion object { fun of(name: String?) = entries.firstOrNull { it.name == name } ?: CLOUDFLARE }
    }

    data class Config(
        val enabled: Boolean = false,
        val provider: Provider = Provider.CLOUDFLARE,
        val customName: String = "",
        val customUrl: String = "",
        val customBootstrap: List<String> = emptyList(),
        val localUsesSystem: Boolean = true,
    ) {
        /** The resolver in use, or null when App DNS is off or a custom address is not valid. */
        val resolver: Resolver? get() {
            if (!enabled) return null
            val url = (provider.url ?: validate(customUrl).getOrNull()) ?: return null
            val boot = (if (provider == Provider.CUSTOM) customBootstrap else provider.bootstrap).filter(::isIpLiteral)
            return Resolver(if (provider == Provider.CUSTOM) customName.trim().ifEmpty { "Custom DNS" } else provider.label, url, boot)
        }
    }

    data class Resolver(val name: String, val url: String, val bootstrap: List<String>)

    class Invalid(message: String) : Exception(message)

    /** A custom address must be https, without a login or a fragment, and name a server. */
    fun validate(text: String): Result<String> {
        val t = text.trim()
        if (t.isEmpty()) return Result.failure(Invalid("Enter the DNS-over-HTTPS address."))
        if (!t.startsWith("https://", ignoreCase = true)) return Result.failure(Invalid("The address must start with https://."))
        val url = t.toHttpUrlOrNull() ?: return Result.failure(Invalid("That is not a valid address."))
        if (url.username.isNotEmpty() || url.password.isNotEmpty()) return Result.failure(Invalid("The address cannot contain a user name or password."))
        if (url.fragment != null) return Result.failure(Invalid("The address cannot contain a # fragment."))
        return Result.success(url.toString())
    }

    private val ipv4 = Regex("^(\\d{1,3})\\.(\\d{1,3})\\.(\\d{1,3})\\.(\\d{1,3})$")
    fun isIpLiteral(s: String): Boolean = ipv4.matches(s) && s.split('.').all { it.toInt() in 0..255 } || (':' in s && s.all { it.isDigit() || it in 'a'..'f' || it in 'A'..'F' || it == ':' || it == '.' })

    /** A name that is on this network and so may use the device's DNS. A name is not local because an answer for it was a private address. */
    fun isLocalName(host: String): Boolean {
        val h = host.lowercase().trim('.', '[', ']')
        if (h.isEmpty()) return false
        if (isIpLiteral(h)) return isPrivateAddress(h)
        return h == "localhost" || h.endsWith(".local") || h.endsWith(".localhost") || h.endsWith(".lan") || h.endsWith(".home.arpa") || h.endsWith(".internal") || '.' !in h
    }

    fun isPrivateAddress(text: String): Boolean {
        val s = text.trim('[', ']')
        ipv4.matchEntire(s)?.let { m ->
            val (a, b) = m.groupValues[1].toInt() to m.groupValues[2].toInt()
            return a == 10 || a == 127 || a == 0 || (a == 172 && b in 16..31) || (a == 192 && b == 168) || (a == 169 && b == 254) || (a == 100 && b in 64..127)
        }
        if (':' in s) {
            val b = runCatching { InetAddress.getByName(s).address }.getOrNull() ?: return false
            if (b.size != 16) return false
            if (b.dropLast(1).all { it.toInt() == 0 } && (b.last().toInt() == 1 || b.last().toInt() == 0)) return true
            val b0 = b[0].toInt() and 0xFF; val b1 = b[1].toInt() and 0xFF
            return (b0 and 0xFE) == 0xFC || (b0 == 0xFE && (b1 and 0xC0) == 0x80)
        }
        return false
    }

    /** DNS-rebinding guard: a public name must not resolve to a private address. */
    fun acceptsAnswer(host: String, address: String, sourceIsLocal: Boolean = false): Boolean = sourceIsLocal || isLocalName(host) || !isPrivateAddress(address)

    private class On(val config: Config, val name: String, val doh: Dns)
    @Volatile private var state: On? = null

    /** Applied when the setting changes, and at start before the first request. Replaces the resolver; the HTTP client reads it for each lookup, so no client has to be rebuilt. */
    fun configure(config: Config, cacheDir: File? = null) {
        val r = config.resolver
        state = if (r == null) null else On(config, r.name, buildDoh(r, cacheDir))
        Http.client.connectionPool.evictAll()            // later requests connect afresh through the new resolver; a stream already playing carries on
    }

    internal fun configureForTest(config: Config, doh: Dns) { state = if (config.enabled) On(config, config.resolver?.name ?: "Test", doh) else null }

    val isOn: Boolean get() = state != null

    private fun buildDoh(r: Resolver, cacheDir: File?): Dns {
        val bootstrapClient = OkHttpClient.Builder().apply { if (cacheDir != null) cache(Cache(File(cacheDir, "app-dns"), 1_000_000L)) }.build()
        return DnsOverHttps.Builder().client(bootstrapClient).url(r.url.toHttpUrlOrNull()!!)
            .bootstrapDnsHosts(r.bootstrap.map { InetAddress.getByName(it) }).includeIPv6(true).build()
    }

    fun clearCache() { (cacheOf(state?.doh))?.evictAll() }
    private fun cacheOf(d: Dns?): Cache? = (d as? DnsOverHttps)?.client?.cache

    override fun lookup(hostname: String): List<InetAddress> {
        val s = state ?: return Dns.SYSTEM.lookup(hostname)
        if (s.config.localUsesSystem && isLocalName(hostname)) return Dns.SYSTEM.lookup(hostname)
        val answers = try { s.doh.lookup(hostname) } catch (e: UnknownHostException) {
            throw UnknownHostException("App DNS (${s.name}) could not resolve $hostname").apply { initCause(e) }      // never handed to the device's DNS
        }
        val usable = answers.filter { acceptsAnswer(hostname, it.hostAddress.orEmpty()) }
        if (usable.isEmpty() && answers.isNotEmpty()) throw UnknownHostException("App DNS (${s.name}) refused $hostname: a public name pointed at a private address")
        return usable
    }

    data class TestRow(val label: String, val host: String, val resolved: Boolean, val detail: String)
    data class TestResult(val resolverName: String, val reachable: Boolean, val milliseconds: Long, val rows: List<TestRow>, val comparison: String?)

    /** Asks the chosen resolver for a public name and each given (label, address); only host names are used, never a path, login or query. */
    fun test(config: Config, hosts: List<Pair<String, String>>, cacheDir: File? = null, doh: Dns? = null, system: Dns = Dns.SYSTEM): TestResult {
        val r = config.copy(enabled = true).resolver ?: return TestResult("Custom DNS", false, 0, emptyList(), null)
        val resolver = doh ?: buildDoh(r, null)
        val names = mutableListOf("Public host name" to "example.com")
        hosts.forEach { (label, address) -> hostOnly(address)?.let { h -> if (names.none { it.second == h } && !isLocalName(h)) names += label to h } }
        val rows = mutableListOf<TestRow>(); val differs = mutableListOf<String>(); var answered = 0; var total = 0L
        for ((label, host) in names) {
            val t0 = System.nanoTime()
            val result = runCatching { resolver.lookup(host) }
            total += (System.nanoTime() - t0) / 1_000_000
            val addrs = result.getOrNull().orEmpty()
            val usable = addrs.filter { acceptsAnswer(host, it.hostAddress.orEmpty()) }
            if (result.isSuccess) answered++
            val ok = usable.isNotEmpty()
            rows += TestRow(label, host, ok, when { ok -> "Resolved · ${usable.size} address${if (usable.size == 1) "" else "es"}"; addrs.isNotEmpty() -> "Refused: a public name pointed at a private address"; result.isFailure && result.exceptionOrNull() is UnknownHostException -> "Not found or blocked"; else -> "The DNS server could not be reached" })
            if (!config.enabled && ok && runCatching { system.lookup(host) }.isFailure) differs += label
        }
        val comparison = when {
            config.enabled -> "The comparison with the device's own DNS is shown while App DNS is off."
            differs.isNotEmpty() -> "The device's DNS could not resolve: ${differs.joinToString()}. App DNS may fix this playback problem."
            rows.any { it.resolved } -> "Both App DNS and the device's DNS returned an answer. A playback problem is probably not caused by DNS."
            else -> null
        }
        return TestResult(r.name, answered > 0, total / names.size, rows, comparison)
    }

    /** The bare host name of an address, or null; a path, query, login or port never survives. */
    fun hostOnly(address: String): String? = address.trim().let { a -> (if ("://" in a) a else "https://$a").toHttpUrlOrNull()?.host?.takeIf { '.' in it || it.all { c -> c.isLetterOrDigit() || c == '-' } } }

    const val PRIVACY_NOTICE = "When App DNS is on, the DNS provider you choose can see the domain names StreamSetu looks up. It does not receive playlist passwords, stream paths or viewing history in those requests. The provider may still be able to tell which IPTV or CDN service you use from the host name."
}
