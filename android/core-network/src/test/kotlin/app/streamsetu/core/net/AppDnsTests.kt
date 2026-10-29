package app.streamsetu.core.net

import okhttp3.Dns
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import java.net.InetAddress
import java.net.UnknownHostException

class AppDnsTests {
    @After fun off() = AppDns.configureForTest(AppDns.Config(), Dns.SYSTEM)

    private fun ip(s: String) = InetAddress.getByAddress(s.split('.').map { it.toInt().toByte() }.toByteArray())
    private val on = AppDns.Config(enabled = true)
    private fun dns(f: (String) -> List<InetAddress>): Dns = object : Dns { override fun lookup(hostname: String) = f(hostname) }

    @Test fun offByDefaultAndTheProviderIsRememberedButInactive() {
        val c = AppDns.Config()
        assertFalse(c.enabled); assertEquals(AppDns.Provider.CLOUDFLARE, c.provider); assertNull(c.resolver)
        assertEquals("https://cloudflare-dns.com/dns-query", on.resolver?.url)
    }

    @Test fun everyBuiltInProviderIsHttpsWithBootstrapAddresses() {
        AppDns.Provider.entries.filter { it != AppDns.Provider.CUSTOM }.forEach { p ->
            assertTrue(p.label, p.url!!.startsWith("https://")); assertTrue(p.label, p.bootstrap.isNotEmpty() && p.bootstrap.all(AppDns::isIpLiteral))
        }
    }

    @Test fun customAddressesAreValidated() {
        fun bad(s: String) = AppDns.validate(s).isFailure
        assertTrue(bad("")); assertTrue(bad("http://dns.example/dns-query")); assertTrue(bad("dns.example/q"))
        assertTrue(bad("https://user:pw@dns.example/dns-query")); assertTrue(bad("https://dns.example/dns-query#x"))
        assertTrue(AppDns.validate(" https://dns.example/dns-query ").isSuccess)
        val c = AppDns.Config(enabled = true, provider = AppDns.Provider.CUSTOM, customUrl = "http://dns.example/q")
        assertNull("an invalid custom address never becomes a resolver", c.resolver)
        assertEquals(listOf("9.9.9.9"), c.copy(customUrl = "https://dns.example/dns-query", customBootstrap = listOf("9.9.9.9", "nope")).resolver?.bootstrap)
    }

    @Test fun localNamesAreOnlyLocalNames() {
        listOf("nas", "plex.local", "NAS.LOCAL.", "router.lan", "192.168.1.20", "10.0.0.5", "172.16.3.1", "169.254.1.1", "127.0.0.1", "fd00::1", "fe80::1", "localhost").forEach { assertTrue(it, AppDns.isLocalName(it)) }
        listOf("example.com", "cdn.provider.tv", "8.8.8.8", "172.32.0.1", "2606:4700:4700::1111", "local.example.com").forEach { assertFalse(it, AppDns.isLocalName(it)) }
    }

    @Test fun remoteNamesGoThroughTheResolverAndLocalOnesToTheDevice() {
        var asked = ""
        AppDns.configureForTest(on, dns { h -> asked = h; listOf(ip("203.0.113.7")) })
        assertEquals("203.0.113.7", AppDns.lookup("cdn.provider.tv").single().hostAddress); assertEquals("cdn.provider.tv", asked)
        asked = ""
        runCatching { AppDns.lookup("nas.local") }                      // the device's DNS is asked (and here cannot answer); the encrypted resolver is not
        assertEquals("", asked)
    }

    @Test fun aFailureNeverFallsBackToTheDevicesDns() {
        AppDns.configureForTest(on, dns { throw UnknownHostException("blocked") })
        val e = runCatching { AppDns.lookup("example.com") }.exceptionOrNull()
        assertTrue(e is UnknownHostException); assertTrue(e!!.message!!.contains("App DNS"))
    }

    @Test fun aPublicNameCannotResolveToAPrivateAddress() {
        AppDns.configureForTest(on, dns { listOf(ip("192.168.1.1")) })
        assertTrue(runCatching { AppDns.lookup("cdn.provider.tv") }.exceptionOrNull() is UnknownHostException)
        AppDns.configureForTest(on, dns { listOf(ip("192.168.1.1"), ip("203.0.113.9")) })
        assertEquals(listOf("203.0.113.9"), AppDns.lookup("cdn.provider.tv").map { it.hostAddress })
    }

    @Test fun offUsesTheDevicesDns() {
        AppDns.configureForTest(AppDns.Config(), dns { error("must not be asked") })
        assertFalse(AppDns.isOn)
        assertTrue(AppDns.lookup("localhost").isNotEmpty())
    }

    @Test fun theTestUsesHostNamesOnlyAndSaysWhatItFound() {
        val seen = mutableListOf<String>()
        val doh = dns { h -> seen += h; if (h == "provider.tv") listOf(ip("203.0.113.7")) else if (h == "guide.tv") listOf(ip("192.168.1.1")) else listOf(ip("93.184.216.34")) }
        val r = AppDns.test(AppDns.Config(), listOf("Playlist" to "http://u:p@provider.tv:8080/get.php?username=u&password=p", "Guide" to "https://guide.tv/x.xml", "Local" to "http://nas.local/l.m3u"), doh = doh,
            system = dns { if (it == "provider.tv") throw UnknownHostException() else listOf(ip("1.2.3.4")) })
        assertEquals(listOf("example.com", "provider.tv", "guide.tv"), seen)
        assertTrue(r.reachable); assertTrue(r.rows[1].resolved); assertFalse(r.rows[2].resolved); assertTrue(r.rows[2].detail.contains("private"))
        assertTrue(r.comparison!!.contains("Playlist"))
        assertEquals("provider.tv", AppDns.hostOnly("https://user:pw@provider.tv:8080/live/1.ts?token=abc"))
    }
}
