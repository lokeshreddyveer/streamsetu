package app.streamsetu.core.data.lan

import app.streamsetu.core.sync.lan.LanCrypto
import app.streamsetu.core.sync.lan.LanData
import app.streamsetu.core.sync.lan.LanLink
import app.streamsetu.core.sync.lan.LanOutcome
import app.streamsetu.core.sync.lan.LanPeer
import app.streamsetu.core.sync.lan.LanProtocol
import app.streamsetu.core.sync.lan.LanRecord
import app.streamsetu.core.sync.lan.LanTrust
import app.streamsetu.core.sync.lan.SourceKey
import app.streamsetu.core.sync.lan.shouldApply
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LanProtocolTests {
    private class Pipe : LanLink {
        val outgoing = LinkedBlockingQueue<ByteArray>(); lateinit var peer: Pipe
        var tamper = false
        override fun send(frame: ByteArray) { peer.outgoing.put(if (tamper && frame.size > 40) frame.copyOf().also { it[it.size - 1] = (it[it.size - 1] + 1).toByte() } else frame) }
        override fun receive(): ByteArray = outgoing.poll(5, TimeUnit.SECONDS) ?: error("nothing arrived")
    }
    private fun links(): Pair<Pipe, Pipe> { val a = Pipe(); val b = Pipe(); a.peer = b; b.peer = a; return a to b }

    private class Trust : LanTrust {
        val peers = mutableListOf<LanPeer>()
        override fun find(publicX963: ByteArray) = peers.firstOrNull { it.publicX963.contentEquals(publicX963) }
        override fun add(peer: LanPeer) { peers.removeAll { it.id == peer.id }; peers += peer }
    }

    private class Store(vararg start: LanRecord) : LanData {
        val items = start.associateBy { it.identity }.toMutableMap()
        override fun snapshot() = items.values.toList()
        override fun apply(records: List<LanRecord>): Int {
            var n = 0
            for (r in records) if (shouldApply(items[r.identity]?.ts, r.ts)) { items[r.identity] = r; n++ }
            return n
        }
    }

    private fun fav(item: String, ts: Long, deleted: Boolean = false) = LanRecord("fav", listOf("srcA", "movie", item, "favorites"), ts, deleted, if (deleted) null else buildJsonObject { put("at", ts) })

    private class Device(name: String, val store: Store, var offering: Boolean = false, var answer: Boolean = true) {
        val identity = LanCrypto.newIdentity(); val trust = Trust(); var seen: String? = null
        val protocol = LanProtocol(identity, name, trust, store, { offering }, { digits, _ -> seen = digits; answer })
    }

    private fun run(a: Device, b: Device, pipes: Pair<Pipe, Pipe> = links()): Pair<LanOutcome, LanOutcome> {
        var responder: LanOutcome? = null
        val t = thread { responder = b.protocol.runResponder(pipes.second) }
        val initiator = a.protocol.runInitiator(pipes.first)
        t.join(8000)
        return initiator to responder!!
    }

    @Test fun twoNewDevicesPairWhenTheDigitsMatchAndThenShareEverything() {
        val a = Device("Phone", Store(fav("1", 100), fav("2", 200))); val b = Device("TV", Store(fav("3", 300)), offering = true)
        val (x, y) = run(a, b)
        assertTrue(x.toString(), x is LanOutcome.Synced && x.paired && x.received == 1)
        assertTrue(y.toString(), y is LanOutcome.Synced && y.paired && y.received == 2)
        assertEquals(a.store.items.keys, b.store.items.keys); assertEquals(3, a.store.items.size)
        assertEquals(a.seen, b.seen); assertEquals(6, a.seen!!.length)
        assertEquals(1, a.trust.peers.size); assertEquals(1, b.trust.peers.size)
    }

    @Test fun pairedDevicesSyncAgainWithoutPairingAndNewerChangesWin() {
        val a = Device("Phone", Store(fav("1", 100))); val b = Device("TV", Store(), offering = true)
        run(a, b)
        a.store.items[fav("1", 0).identity] = fav("1", 500, deleted = true)       // removed on the phone later
        b.store.items[fav("9", 0).identity] = fav("9", 600)
        b.offering = false
        val (x, y) = run(a, b)
        assertTrue(x is LanOutcome.Synced && !(x as LanOutcome.Synced).paired)
        assertTrue(y is LanOutcome.Synced)
        assertTrue(b.store.items[fav("1", 0).identity]!!.deleted)
        assertEquals(setOf(fav("1", 0).identity, fav("9", 0).identity), a.store.items.keys)
    }

    @Test fun aDeviceThatIsNotShowingAddADeviceRefusesANewOne() {
        val a = Device("Phone", Store(fav("1", 100))); val b = Device("TV", Store(), offering = false)
        val (x, y) = run(a, b)
        assertTrue(x.toString(), x is LanOutcome.Refused); assertTrue(y.toString(), y is LanOutcome.Refused)
        assertEquals(0, b.store.items.size); assertTrue(b.trust.peers.isEmpty())
    }

    @Test fun decliningTheDigitsPairsNothing() {
        val a = Device("Phone", Store(fav("1", 100))); val b = Device("TV", Store(), offering = true, answer = false)
        val (x, y) = run(a, b)
        assertTrue(x is LanOutcome.Refused && y is LanOutcome.Refused)
        assertTrue(a.trust.peers.isEmpty() && b.trust.peers.isEmpty()); assertEquals(0, b.store.items.size)
    }

    @Test fun aChangedFrameIsRejectedInsteadOfApplied() {
        val a = Device("Phone", Store(fav("1", 100))); val b = Device("TV", Store(), offering = true)
        val pipes = links(); pipes.first.tamper = true
        val (x, _) = run(a, b, pipes)
        assertTrue(x.toString(), x is LanOutcome.Failed)
        assertEquals(0, b.store.items.size)
    }

    @Test fun bigStatesTravelInSeveralFrames() {
        val many = (1..4000).map { fav("m$it", it.toLong()) }.toTypedArray()
        val a = Device("Phone", Store(*many)); val b = Device("TV", Store(), offering = true)
        val (x, _) = run(a, b)
        assertTrue(x is LanOutcome.Synced); assertEquals(4000, b.store.items.size)
    }

    @Test fun theSameStateSentAgainChangesNothing() {
        assertFalse(shouldApply(100, 100)); assertTrue(shouldApply(100, 101)); assertTrue(shouldApply(null, 1))
    }

    @Test fun aPlaylistHasTheSameKeyOnEveryDevice() {
        assertEquals(SourceKey.of("http://Example.com:8080/"), SourceKey.of("https://example.com:8080"))
        assertNotEquals(SourceKey.of("http://a.example"), SourceKey.of("http://b.example")); assertEquals(16, SourceKey.of("x").length)
    }

    @Test fun sharedSecretSessionKeyAndDigitsAgreeOnBothSides() {
        val a = LanCrypto.newIdentity(); val b = LanCrypto.newIdentity()
        val za = LanCrypto.sharedSecret(a.privatePkcs8, b.publicX963); val zb = LanCrypto.sharedSecret(b.privatePkcs8, a.publicX963)
        assertArrayEquals(za, zb)
        val na = LanCrypto.randomBytes(16); val nb = LanCrypto.randomBytes(16)
        assertArrayEquals(LanCrypto.sessionKey(za, na, nb), LanCrypto.sessionKey(zb, na, nb))
        assertEquals(LanCrypto.comparisonDigits(za, a.publicX963, b.publicX963), LanCrypto.comparisonDigits(zb, a.publicX963, b.publicX963))
        val k = LanCrypto.sessionKey(za, na, nb)
        val sender = LanCrypto.Channel(k, 0); val receiver = LanCrypto.Channel(k, 1)
        assertArrayEquals("hello".toByteArray(), receiver.open(sender.seal("hello".toByteArray())))
        assertEquals(65, a.publicX963.size); assertEquals(16, a.deviceId.length); assertNull(null)
    }

    private fun unhex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    private fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }

    /** The same numbers the Apple apps work out (their test has the same values); if these differ, the two kinds of device cannot talk to each other. */
    @Test fun theCryptographyMatchesTheNumbersFromTheAppleApps() {
        val pubA = unhex("040217e617f0b6443928278f96999e69a23a4f2c152bdf6d6cdf66e5b80282d4ed194a7debcb97712d2dda3ca85aa8765a56f45fc758599652f2897c65306e5794")
        val pubB = unhex("04d65a93977caa3d1b081852ff57a79e465f1660577304baead505dd3a48589cf350185e895372df6221ea3a137557e473fddb6755f05bd507c3c533fce9c91285")
        val privA = LanCrypto.pkcs8FromScalar(ByteArray(32) { 0x11 }); val privB = LanCrypto.pkcs8FromScalar(ByteArray(32) { 0x22 })
        val z = LanCrypto.sharedSecret(privA, pubB)
        assertEquals("ccfc261f58193c98ca4ad4a53bbac6f0ee29bc4d48438090446908622ca79af6", hex(z))
        assertArrayEquals(z, LanCrypto.sharedSecret(privB, pubA))
        val key = LanCrypto.sessionKey(z, ByteArray(16) { it.toByte() }, ByteArray(16) { (16 + it).toByte() })
        assertEquals("a48b506918bd86d0a1c9b82fb660e2e50f776fa06db1a39b6bb78e0115e7dbe2", hex(key))
        assertEquals("402091", LanCrypto.comparisonDigits(z, pubA, pubB))
        val sender = LanCrypto.Channel(key, 0)
        assertEquals("a4fd7a2bf16c11516c2453d157a6210464a8ebb07461180a6de733f158fa15b4", hex(sender.seal("hello streamsetu".toByteArray())))
        assertEquals("a6c088b12781d5f759f4372a646ff748f7f174d2f3", hex(sender.seal("again".toByteArray())))
        assertEquals("2bad0fd610d99eae", LanCrypto.deviceId(pubA))
        val receiver = LanCrypto.Channel(key, 1)
        assertArrayEquals("hello streamsetu".toByteArray(), receiver.open(unhex("a4fd7a2bf16c11516c2453d157a6210464a8ebb07461180a6de733f158fa15b4")))
    }
}
