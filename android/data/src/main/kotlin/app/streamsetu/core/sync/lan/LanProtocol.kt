package app.streamsetu.core.sync.lan

import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/** A framed, ordered link between two devices (a TCP connection in the app, a pair of queues in the tests). Both calls block. */
interface LanLink {
    fun send(frame: ByteArray)
    fun receive(): ByteArray
}

class LanPeer(val id: String, val name: String, val publicX963: ByteArray)

/** The devices this one has been paired with. */
interface LanTrust {
    fun find(publicX963: ByteArray): LanPeer?
    fun add(peer: LanPeer)
}

/** What is kept in step: everything this device has, and a place to put what the other device sent. */
interface LanData {
    fun snapshot(): List<LanRecord>
    /** Applies records that arrived, keeping each one only when it is newer than what is here. Returns how many changed something. */
    fun apply(records: List<LanRecord>): Int
}

sealed interface LanOutcome {
    data class Synced(val peer: LanPeer, val received: Int, val paired: Boolean) : LanOutcome
    data class Refused(val reason: String) : LanOutcome
    data class Failed(val message: String) : LanOutcome
}

/**
 * The conversation between two devices, as in docs/WIFI-SYNC.md: hello, a session key, pairing when the other device is new, then one exchange of everything each side has.
 * [offerPairing] says whether this device is showing its "Add a device" screen; [confirm] shows the six digits to the person and waits for their answer.
 */
@OptIn(ExperimentalEncodingApi::class)
class LanProtocol(
    private val identity: LanCrypto.Identity, private val deviceName: String, private val trust: LanTrust, private val data: LanData,
    private val offerPairing: () -> Boolean, private val confirm: (digits: String, peerName: String) -> Boolean,
    private val chunk: Int = 1500,
) {
    private fun String.fromB64(): ByteArray = Base64.decode(this)
    private fun ByteArray.toB64(): String = Base64.encode(this)

    fun runInitiator(link: LanLink): LanOutcome = guarded {
        val nonce = LanCrypto.randomBytes(16)
        link.send(hello(nonce))
        val reply = LanJson.parse(link.receive())
        val peerPub = reply["pub"]!!.jsonPrimitive.content.fromB64(); val peerName = reply["name"]!!.jsonPrimitive.content
        val peerNonce = reply["nonce"]!!.jsonPrimitive.content.fromB64()
        val z = LanCrypto.sharedSecret(identity.privatePkcs8, peerPub)
        val channel = LanCrypto.Channel(LanCrypto.sessionKey(z, nonce, peerNonce), 0)
        val known = trust.find(peerPub)
        link.send(channel.seal(LanJson.bytes(LanJson.message("start") { put("mode", if (known == null) "pair" else "sync") })))
        var paired = false
        var peer = known ?: LanPeer(LanCrypto.deviceId(peerPub), peerName, peerPub)
        val first = LanJson.parse(channel.open(link.receive()))
        when (LanJson.type(first)) {
            "reject" -> return@guarded LanOutcome.Refused(first["why"]?.jsonPrimitive?.contentOrNull ?: "refused")
            "pair" -> { // the other device is ready to pair: compare the digits
                val digits = LanCrypto.comparisonDigits(z, identity.publicX963, peerPub)
                val ok = confirm(digits, peerName)
                link.send(channel.seal(LanJson.bytes(LanJson.message("pair") { put("ok", ok) })))
                val theirs = LanJson.parse(channel.open(link.receive()))
                if (!ok || theirs["ok"]?.jsonPrimitive?.contentOrNull != "true") return@guarded LanOutcome.Refused("not confirmed")
                trust.add(peer); paired = true
            }
            "ready" -> {}
            else -> return@guarded LanOutcome.Failed("unexpected answer")
        }
        sendState(link, channel, data.snapshot())
        var received = 0
        while (true) {
            val m = LanJson.parse(channel.open(link.receive()))
            if (LanJson.type(m) != "state") return@guarded LanOutcome.Failed("unexpected answer")
            received += data.apply(LanJson.recordsOf(m))
            if (m["more"]?.jsonPrimitive?.contentOrNull != "true") break
        }
        link.send(channel.seal(LanJson.bytes(LanJson.message("bye"))))
        LanOutcome.Synced(peer, received, paired)
    }

    fun runResponder(link: LanLink): LanOutcome = guarded {
        val first = LanJson.parse(link.receive())
        val peerPub = first["pub"]!!.jsonPrimitive.content.fromB64(); val peerName = first["name"]!!.jsonPrimitive.content
        val peerNonce = first["nonce"]!!.jsonPrimitive.content.fromB64()
        val nonce = LanCrypto.randomBytes(16)
        link.send(hello(nonce))
        val z = LanCrypto.sharedSecret(identity.privatePkcs8, peerPub)
        val channel = LanCrypto.Channel(LanCrypto.sessionKey(z, peerNonce, nonce), 1)
        val start = LanJson.parse(channel.open(link.receive()))
        val wantsPairing = start["mode"]?.jsonPrimitive?.contentOrNull == "pair"
        val known = trust.find(peerPub)
        var paired = false
        var peer = known ?: LanPeer(LanCrypto.deviceId(peerPub), peerName, peerPub)
        if (wantsPairing || known == null) {
            if (!offerPairing()) { link.send(channel.seal(LanJson.bytes(LanJson.message("reject") { put("why", "not-paired") }))); return@guarded LanOutcome.Refused("not paired") }
            link.send(channel.seal(LanJson.bytes(LanJson.message("pair"))))
            val digits = LanCrypto.comparisonDigits(z, peerPub, identity.publicX963)
            val ok = confirm(digits, peerName)
            val theirs = LanJson.parse(channel.open(link.receive()))
            link.send(channel.seal(LanJson.bytes(LanJson.message("pair") { put("ok", ok) })))
            if (!ok || theirs["ok"]?.jsonPrimitive?.contentOrNull != "true") return@guarded LanOutcome.Refused("not confirmed")
            trust.add(peer); paired = true
        } else link.send(channel.seal(LanJson.bytes(LanJson.message("ready"))))
        var received = 0
        while (true) {
            val m = LanJson.parse(channel.open(link.receive()))
            if (LanJson.type(m) != "state") return@guarded LanOutcome.Failed("unexpected message")
            received += data.apply(LanJson.recordsOf(m))
            if (m["more"]?.jsonPrimitive?.contentOrNull != "true") break
        }
        sendState(link, channel, data.snapshot())
        val bye = LanJson.parse(channel.open(link.receive()))
        if (LanJson.type(bye) != "bye") return@guarded LanOutcome.Failed("unexpected message")
        LanOutcome.Synced(peer, received, paired)
    }

    private fun hello(nonce: ByteArray): ByteArray = LanJson.bytes(LanJson.message("hello") {
        put("v", 1); put("pub", identity.publicX963.toB64()); put("name", deviceName); put("nonce", nonce.toB64())
    })

    private fun sendState(link: LanLink, channel: LanCrypto.Channel, records: List<LanRecord>) {
        if (records.isEmpty()) { link.send(channel.seal(LanJson.bytes(LanJson.withRecords("state", emptyList(), false)))); return }
        records.chunked(chunk).forEachIndexed { i, part ->
            link.send(channel.seal(LanJson.bytes(LanJson.withRecords("state", part, (i + 1) * chunk < records.size))))
        }
    }

    private inline fun guarded(block: () -> LanOutcome): LanOutcome = try { block() } catch (e: Exception) { LanOutcome.Failed(e.message ?: e.javaClass.simpleName) }
}
