package app.streamsetu.core.addon

import okio.Buffer
import org.junit.Assert.*
import org.junit.Test

class AddonTests {
    private fun manifest(
        id: String = "provider.example", capabilities: String = "[\"catalog\",\"stream\"]", auth: String = "usernamePassword",
        endpoints: String = "{\"catalog\":\"https://api.example.com/catalog\",\"stream\":\"https://api.example.com/stream\"}", hosts: String = "[\"api.example.com\",\"cdn.example.com\"]",
        limits: String = "{\"timeoutSeconds\":10,\"maxResponseBytes\":10485760}", schema: Int = 1, extra: String = "",
    ) = """{"schema":$schema,"id":"$id","name":"Example Provider","capabilities":$capabilities,"authentication":{"type":"$auth"},"endpoints":$endpoints,"allowedHosts":$hosts,"limits":$limits$extra}"""

    private fun refused(text: String) = (AddonManifestParser.parse(text) as? ManifestResult.Refused)?.reasons ?: emptyList()

    @Test fun aWellFormedManifestIsAccepted() { assertTrue(AddonManifestParser.parse(manifest()) is ManifestResult.Valid) }

    @Test fun aFieldThatIsNotPartOfTheFormatIsRefused() { assertTrue(refused(manifest(extra = ",\"script\":\"alert(1)\"")).isNotEmpty()) }

    @Test fun anEndpointOnAServerThatWasNotNamedIsRefused() {
        val r = refused(manifest(endpoints = "{\"catalog\":\"https://evil.example.org/catalog\",\"stream\":\"https://api.example.com/stream\"}"))
        assertTrue(r.any { "evil.example.org" in it })
    }

    @Test fun plainHttpUserNamesInAddressesAndPortsOutOfRangeAreRefused() {
        assertTrue(refused(manifest(endpoints = "{\"catalog\":\"http://api.example.com/c\",\"stream\":\"https://api.example.com/s\"}")).isNotEmpty())
        assertTrue(refused(manifest(endpoints = "{\"catalog\":\"https://me@api.example.com/c\",\"stream\":\"https://api.example.com/s\"}")).isNotEmpty())
        assertTrue(refused(manifest(endpoints = "{\"catalog\":\"https://api.example.com:99999/c\",\"stream\":\"https://api.example.com/s\"}")).isNotEmpty())
    }

    @Test fun privateAndLocalServersAreRefused() {
        listOf("localhost", "router.local", "192.168.1.5", "10.0.0.2", "127.0.0.1", "169.254.169.254", "intranet.internal").forEach { h ->
            assertTrue("$h should be refused", refused(manifest(hosts = "[\"$h\"]", endpoints = "{\"catalog\":\"https://$h/c\",\"stream\":\"https://$h/s\"}")).isNotEmpty())
        }
    }

    @Test fun addressesWrittenOutAreJudgedAsAddressesNotAsNames() {
        listOf("100.64.0.1", "100.100.100.200", "198.18.0.1", "192.0.0.8", "224.0.0.1", "240.0.0.1", "169.254.169.254", "10.1.1.1", "127.0.0.1", "0.0.0.0").forEach { h ->
            assertTrue("$h should be refused", refused(manifest(hosts = "[\"$h\"]", endpoints = "{\"catalog\":\"https://$h/c\",\"stream\":\"https://$h/s\"}")).isNotEmpty())
            assertTrue("$h is private", AddonManifestParser.isPrivate(h))
        }
        assertFalse(AddonManifestParser.isPrivate("8.8.8.8")); assertFalse(AddonManifestParser.isPrivate("api.example.com"))
    }

    @Test fun wildcardsPathsAndPortsInTheHostListAreRefused() {
        listOf("*.example.com", "api.example.com/x", "api.example.com:8443").forEach { h -> assertTrue("$h", refused(manifest(hosts = "[\"$h\",\"api.example.com\"]")).isNotEmpty()) }
    }

    @Test fun anEndpointForSomethingNotDeclaredAndADeclaredCapabilityWithoutAnEndpointAreBothRefused() {
        assertTrue(refused(manifest(capabilities = "[\"catalog\"]")).any { "stream" in it })
        assertTrue(refused(manifest(endpoints = "{\"catalog\":\"https://api.example.com/c\"}")).any { "stream" in it })
        assertTrue(refused(manifest(capabilities = "[\"catalog\",\"shell\"]")).any { "shell" in it })
    }

    @Test fun limitsOutsideTheAllowedRangeAreRefused() {
        assertTrue(refused(manifest(limits = "{\"timeoutSeconds\":120,\"maxResponseBytes\":1048576}")).isNotEmpty())
        assertTrue(refused(manifest(limits = "{\"timeoutSeconds\":5,\"maxResponseBytes\":9999999999}")).isNotEmpty())
        assertTrue(refused(manifest(limits = "{\"timeoutSeconds\":0,\"maxResponseBytes\":1048576}")).isNotEmpty())
    }

    @Test fun anUnknownSchemaIdAndSignInTypeAreRefused() {
        assertTrue(refused(manifest(schema = 2)).isNotEmpty()); assertTrue(refused(manifest(id = "X")).isNotEmpty()); assertTrue(refused(manifest(auth = "cookie")).isNotEmpty())
    }

    @Test fun textThatIsNotAManifestIsRefusedWithoutAnException() { assertTrue(AddonManifestParser.parse("<html>") is ManifestResult.Refused) }

    @Test fun aRedirectIsCheckedAgainstTheNamedServersAtEveryHop() {
        val hosts = setOf("api.example.com")
        assertNull(AddonClient.checkHop("https://api.example.com/x", hosts))
        assertNotNull(AddonClient.checkHop("https://other.example.org/x", hosts))
        assertNotNull(AddonClient.checkHop("http://api.example.com/x", hosts))
    }

    @Test fun anAnswerLargerThanTheLimitIsRefusedWhetherOrNotItSaidHowBigItIs() {
        assertEquals("ok", AddonClient.readLimited(Buffer().writeUtf8("ok"), -1, 10))
        try { AddonClient.readLimited(Buffer().writeUtf8("x".repeat(50)), -1, 10); fail() } catch (_: AddonException) {}
        try { AddonClient.readLimited(Buffer().writeUtf8("x"), 5_000, 10); fail() } catch (_: AddonException) {}
    }

    @Test fun aCatalogKeepsOnlyWhatIsOnTheAddonsOwnServers() {
        val m = (AddonManifestParser.parse(manifest()) as ManifestResult.Valid).manifest
        val text = """{"categories":[{"id":"c1","name":"Drama","kind":"movie"}],
          "movies":[{"id":"m1","title":"Good","image":"https://cdn.example.com/p.jpg","url":"https://cdn.example.com/m1.m3u8"},
                    {"id":"m2","title":"Tracker","image":"https://tracker.example.net/p.gif"},
                    {"id":"m3","title":"Elsewhere","url":"https://other.example.net/m3.m3u8"},{"id":"m1","title":"Duplicate"}],
          "channels":[{"id":"c1","title":"News","url":"http://api.example.com/plain"}],"future":1}"""
        val c = AddonCatalogParser.parse(text, m)
        assertEquals(listOf("m1"), c.movies.map { it.id }); assertTrue(c.channels.isEmpty()); assertEquals(3, c.dropped)
    }

    @Test fun aStreamAnswerIsUsedOnlyOnTheAddonsOwnServers() {
        val m = (AddonManifestParser.parse(manifest()) as ManifestResult.Valid).manifest
        assertEquals("https://cdn.example.com/a.m3u8", AddonCatalogParser.parseStream("{\"url\":\"https://cdn.example.com/a.m3u8\"}", m))
        assertNull(AddonCatalogParser.parseStream("{\"url\":\"https://elsewhere.example.net/a\"}", m)); assertNull(AddonCatalogParser.parseStream("nope", m))
    }
}
