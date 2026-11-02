package app.streamsetu.core.addon

import okio.ByteString.Companion.decodeBase64
import okio.ByteString.Companion.toByteString
import org.junit.Assert.*
import org.junit.Test
import java.security.KeyPairGenerator
import java.security.Signature
import java.security.spec.ECGenParameterSpec

class OfficialAddonsTests {
    private val pair = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
    private val publicKey = pair.public.encoded.toByteString().base64()
    private fun sign(text: String) = Signature.getInstance("SHA256withECDSA").run { initSign(pair.private); update(text.toByteArray()); sign() }.toByteString().base64()
    private val list = """{"schema":1,"updated":"2026-11-01","addons":[{"id":"provider.example","name":"Example","manifestUrl":"https://example.com/addon.json","sha256":"${"a".repeat(64)}"}]}"""

    @Test fun aListSignedWithTheKeyIsUsed() { assertEquals(listOf("provider.example"), OfficialAddons.parse(list, sign(list), publicKey).map { it.id }) }

    @Test fun aListChangedByOneCharacterIsNotUsed() {
        val sig = sign(list)
        try { OfficialAddons.parse(list.replace("Example", "Exampla"), sig, publicKey); fail() } catch (_: AddonException) {}
        assertFalse(OfficialAddons.verify(list.replace("2026", "2027"), sig, publicKey))
    }

    @Test fun aListSignedByAnotherKeyIsNotUsed() {
        val other = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
        val sig = Signature.getInstance("SHA256withECDSA").run { initSign(other.private); update(list.toByteArray()); sign() }.toByteString().base64()
        assertFalse(OfficialAddons.verify(list, sig, publicKey))
    }

    @Test fun garbageInPlaceOfASignatureOrAKeyIsNotAnException() {
        assertFalse(OfficialAddons.verify(list, "not base64 !!", publicKey)); assertFalse(OfficialAddons.verify(list, sign(list), "AAAA"))
    }

    @Test fun theKeyBuiltIntoTheAppIsAWellFormedP256Key() {
        val key = java.security.KeyFactory.getInstance("EC").generatePublic(java.security.spec.X509EncodedKeySpec(OfficialAddons.PUBLIC_KEY.decodeBase64Bytes()))
        assertEquals("EC", key.algorithm)
    }

    @Test fun theFingerprintIsTheSha256OfTheText() { assertEquals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", OfficialAddons.sha256Hex("abc")) }

    private fun String.decodeBase64Bytes() = decodeBase64()!!.toByteArray()
}

class OfficialListResolutionTests {
    private fun list(seq: Long, vararg ids: String) = OfficialList(1, seq, "2026-11-0$seq", ids.map { OfficialEntry(it, it, "https://example.com/$it.json", "a".repeat(64)) })
    private fun ids(r: OfficialAddons.Resolved) = r.entries.map { it.id }

    @Test fun aHigherNumberedServerListIsUsedAndTheLocalOnesAreIgnored() {
        val r = OfficialAddons.resolve(list(9, "new"), null, list(5, "cached"), list(1, "bundled"))
        assertEquals(listOf("new"), ids(r)); assertEquals(OfficialAddons.Origin.REMOTE, r.origin); assertNull(r.note); assertEquals(9, r.sequence)
    }

    @Test fun aLowerNumberedServerListIsARollbackAndIsNotUsed() {
        val r = OfficialAddons.resolve(list(2, "old"), null, null, list(4, "bundled"))
        assertEquals(listOf("bundled"), ids(r)); assertTrue(r.note!!.contains("older"))
    }

    @Test fun theSameNumberIsNotAReplacementAndIsNotAnError() {
        val r = OfficialAddons.resolve(list(4, "same"), null, list(4, "cached"), list(1, "bundled"))
        assertEquals(listOf("cached"), ids(r)); assertEquals(OfficialAddons.Origin.CACHED, r.origin); assertNull(r.note)
    }

    @Test fun anOlderBundledListNeverComesBackAfterANewerOneWasAccepted() {
        // sequence 7 was accepted, its saved copy is gone, the app still carries sequence 1
        try { OfficialAddons.resolve(null, null, null, list(1, "bundled"), highestAccepted = 7); fail("the older bundled list was shown") } catch (e: AddonException) { assertTrue(e.message!!.contains("newer verified list")) }
        try { OfficialAddons.resolve(list(4, "older-remote"), null, null, list(1, "bundled"), highestAccepted = 7); fail("a rollback was accepted") } catch (_: AddonException) {}
        val r = OfficialAddons.resolve(list(8, "accepted"), null, null, list(1, "bundled"), highestAccepted = 7)
        assertEquals(listOf("accepted"), ids(r)); assertEquals(8, r.sequence)
    }

    @Test fun aSavedListAtTheFloorIsStillUsedButABundledOneBelowItIsNot() {
        assertEquals(listOf("cached"), ids(OfficialAddons.resolve(null, "no answer", list(7, "cached"), list(1, "bundled"), highestAccepted = 7)))
        assertEquals(OfficialAddons.Origin.BUNDLED, OfficialAddons.resolve(null, "no answer", null, list(7, "same-as-floor"), highestAccepted = 7).origin)
    }

    @Test fun anUnreachableServerFallsBackToTheNewestCheckedListAndSaysSo() {
        val r = OfficialAddons.resolve(null, "no answer", list(5, "cached"), list(1, "bundled"))
        assertEquals(listOf("cached"), ids(r)); assertEquals(OfficialAddons.Origin.CACHED, r.origin); assertTrue(r.note!!.contains("could not be used"))
        assertEquals(OfficialAddons.Origin.BUNDLED, OfficialAddons.resolve(null, "bad signature", null, list(1, "b")).origin)
    }

    @Test fun theListTheAppAlreadyHasIsShownWithNoNoteAndNoNetwork() {
        val r = OfficialAddons.local(null, list(1, "bundled")); assertEquals(listOf("bundled"), ids(r)); assertNull(r.note)
    }

    @Test fun aFailureIsNeverAnEmptyList() {
        try { OfficialAddons.resolve(null, "no answer", null, null); fail() } catch (_: AddonException) {}
        val signedEmpty = OfficialAddons.resolve(list(1), null, null, null)
        assertTrue(signedEmpty.entries.isEmpty()); assertEquals(OfficialAddons.Origin.REMOTE, signedEmpty.origin)
    }

    @Test fun theBundledListShippedWithTheAppVerifiesAgainstTheBuiltInKeyAndHasANumber() {
        val base = listOf("src/main/assets/addons", "app/src/main/assets/addons", "../app/src/main/assets/addons").map { java.io.File(it) }.firstOrNull { it.exists() }
        assertNotNull("the bundled list was not found", base)
        val list = OfficialAddons.verifiedList(java.io.File(base, "registry.json").readText(), java.io.File(base, "registry.json.sig").readText())
        assertEquals(1, list.schema); assertTrue(list.sequence >= 1)
    }
}

class PublicOnlyDnsTests {
    private fun ip(s: String) = java.net.InetAddress.getByName(s)

    @Test fun privateLoopbackLinkLocalAndReservedAddressesAreRefused() {
        listOf("127.0.0.1", "10.1.2.3", "192.168.1.5", "172.16.0.9", "172.31.255.255", "169.254.169.254", "100.64.0.1", "0.0.0.0", "198.18.0.1", "240.0.0.1",
            "::1", "::", "fc00::1", "fd12:3456::1", "fe80::1", "fec0::1", "ff02::1", "::ffff:10.0.0.1", "::ffff:127.0.0.1").forEach { assertFalse("$it should be refused", AddonAddresses.isPublic(ip(it))) }
    }

    @Test fun documentationBenchmarkingAndTransitionRangesAreRefusedToo() {
        listOf("192.0.2.1", "198.51.100.7", "203.0.113.9", "192.88.99.1", "192.0.0.8", "198.19.255.1", "255.255.255.255", "224.0.0.1", "2001:db8::1", "100::1", "2001:0:4136:e378:8000:63bf:3fff:fdd2",
            "2002:0a00:0001::1" /* 6to4 around 10.0.0.1 */, "64:ff9b::7f00:1" /* NAT64 around 127.0.0.1 */, "ff00::1").forEach { assertFalse("$it should be refused", AddonAddresses.isPublic(ip(it))) }
    }

    @Test fun theLocalUseNat64RangeIsRefusedFromItsFirstToItsLastAddressAndNoFurther() {
        listOf("64:ff9b:1::", "64:ff9b:1::1", "64:ff9b:1:ffff:ffff:ffff:ffff:ffff").forEach { assertFalse("$it should be refused", AddonAddresses.isPublic(ip(it))) }
        listOf("64:ff9b:0:ffff:ffff:ffff:ffff:ffff" /* just before it */, "64:ff9b:2::1" /* just after it */).forEach { assertTrue("$it should be allowed", AddonAddresses.isPublic(ip(it))) }
    }

    @Test fun addressesJustOutsideTheReservedBlocksAreAccepted() {
        listOf("172.15.255.255", "172.32.0.1", "100.63.255.255", "100.128.0.1", "198.17.255.255", "198.20.0.1", "223.255.255.254", "2002:0808:0808::1" /* 6to4 around 8.8.8.8 */, "64:ff9b::808:808" /* NAT64 around 8.8.8.8 */).forEach { assertTrue("$it should be allowed", AddonAddresses.isPublic(ip(it))) }
    }

    @Test fun publicAddressesAreAccepted() { listOf("8.8.8.8", "1.1.1.1", "93.184.216.34", "2606:4700:4700::1111", "2001:4860:4860::8888").forEach { assertTrue("$it should be allowed", AddonAddresses.isPublic(ip(it))) } }

    private fun dnsOf(answers: List<java.net.InetAddress>) = object : okhttp3.Dns { override fun lookup(hostname: String) = answers }
    private fun resolver(vararg answers: String) = PublicOnlyDns(dnsOf(answers.map { ip(it) }))

    @Test fun aPublicLookingNameThatPointsInsideTheNetworkIsRefused() {
        listOf("127.0.0.1", "10.0.0.5", "192.168.0.10", "::1", "fd00::5").forEach { a -> try { resolver(a).lookup("api.example.com"); fail("$a was accepted") } catch (_: java.net.UnknownHostException) {} }
    }

    @Test fun oneBadAddressAmongGoodOnesRefusesTheName() { try { resolver("8.8.8.8", "10.0.0.1").lookup("api.example.com"); fail() } catch (_: java.net.UnknownHostException) {} }

    @Test fun aNameThatPointsOnlyAtPublicAddressesIsResolvedUnchanged() { assertEquals(listOf(ip("8.8.8.8"), ip("2606:4700:4700::1111")), resolver("8.8.8.8", "2606:4700:4700::1111").lookup("api.example.com")) }

    @Test fun anEmptyAnswerIsRefused() { try { PublicOnlyDns(dnsOf(emptyList())).lookup("api.example.com"); fail() } catch (_: java.net.UnknownHostException) {} }
}

class AddonClientSafetyTests {
    private fun dnsOf(vararg a: String) = object : okhttp3.Dns { override fun lookup(hostname: String) = a.map { java.net.InetAddress.getByName(it) } }

    @Test fun addOnCallsNeverUseTheSettingsProxyAndKeepTheAppsResolver() {
        val withProxy = okhttp3.OkHttpClient.Builder().proxy(java.net.Proxy(java.net.Proxy.Type.HTTP, java.net.InetSocketAddress.createUnresolved("proxy.example.com", 8080))).dns(dnsOf("8.8.8.8")).build()
        val c = AddonClient({ withProxy }).callClient(5)
        assertEquals(java.net.Proxy.NO_PROXY, c.proxy); assertFalse(c.followRedirects); assertFalse(c.followSslRedirects)
        assertEquals(listOf(java.net.InetAddress.getByName("8.8.8.8")), c.dns.lookup("api.example.com"))          // the base client's resolver is still the one asked
    }

    @Test fun theResolverOfAnAddOnCallRefusesAPrivateAnswerFromTheBaseResolver() {
        val c = AddonClient({ okhttp3.OkHttpClient.Builder().dns(dnsOf("10.0.0.5")).build() }).callClient(5)
        try { c.dns.lookup("api.example.com"); fail() } catch (_: java.net.UnknownHostException) {}
    }
}
