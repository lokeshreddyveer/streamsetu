package app.streamsetu.tv

import app.streamsetu.core.sync.lan.LanCrypto
import app.streamsetu.core.sync.lan.LanData
import app.streamsetu.core.sync.lan.LanOutcome
import app.streamsetu.core.sync.lan.LanPeer
import app.streamsetu.core.sync.lan.LanProtocol
import app.streamsetu.core.sync.lan.LanRecord
import app.streamsetu.core.sync.lan.LanTrust
import app.streamsetu.tv.sync.SocketLink
import java.net.ServerSocket
import java.net.Socket
import kotlin.concurrent.thread
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LanSocketTests {
    private class Trust : LanTrust {
        val peers = mutableListOf<LanPeer>()
        override fun find(publicX963: ByteArray) = peers.firstOrNull { it.publicX963.contentEquals(publicX963) }
        override fun add(peer: LanPeer) { peers.add(peer) }
    }
    private class Mem(start: List<LanRecord>) : LanData {
        val items = start.associateBy { it.identity }.toMutableMap()
        override fun snapshot() = items.values.toList()
        override fun apply(records: List<LanRecord>): Int { var n = 0; for (r in records) if (items[r.identity]?.let { r.ts > it.ts } != false) { items[r.identity] = r; n++ }; return n }
    }
    private fun rec(id: String, ts: Long) = LanRecord("fav", listOf("srcA", "movie", id, "favorites"), ts, false, JsonObject(mapOf("at" to JsonPrimitive(ts))))

    /** A real TCP connection on this computer: the framing, the hello, pairing and one exchange all work over it. */
    @Test fun twoDevicesPairAndSyncOverTcp() {
        val server = ServerSocket(0)
        val a = Mem(listOf(rec("one", 10))); val b = Mem(listOf(rec("two", 20)))
        val pa = LanProtocol(LanCrypto.newIdentity(), "A", Trust(), a, { false }, { _, _ -> true })
        val pb = LanProtocol(LanCrypto.newIdentity(), "B", Trust(), b, { true }, { _, _ -> true })
        var responder: LanOutcome? = null
        val t = thread { server.accept().use { responder = pb.runResponder(SocketLink(it)) } }
        val out = Socket("127.0.0.1", server.localPort).use { pa.runInitiator(SocketLink(it)) }
        t.join(20_000)
        assertTrue(out.toString(), out is LanOutcome.Synced)
        assertTrue(responder.toString(), responder is LanOutcome.Synced)
        assertEquals(2, a.items.size); assertEquals(2, b.items.size)
        server.close()
    }
}
