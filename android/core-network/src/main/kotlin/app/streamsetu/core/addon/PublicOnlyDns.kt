package app.streamsetu.core.addon

import okhttp3.Dns
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.net.UnknownHostException

/** Which addresses an add-on may be sent to: public ones only. Names are not enough, because a public-looking name can point at an address inside the person's own network. */
object AddonAddresses {
    private class Block(val bytes: IntArray, val bits: Int) { fun covers(a: ByteArray) = bits == 0 || (0 until (bits + 7) / 8).all { i -> val keep = minOf(8, bits - i * 8); val mask = (0xff shl (8 - keep)) and 0xff; (a[i].toInt() and mask) == (bytes[i] and mask) } }
    private fun v4(vararg b: Int, bits: Int) = Block(b, bits)
    private fun v6(hex: String, bits: Int): Block { val g = java.net.InetAddress.getByName(hex).address; return Block(IntArray(16) { g[it].toInt() and 0xff }, bits) }

    /** Every IPv4 block that is not an ordinary public address (RFC 6890): this network, private, shared (carrier-grade), loopback, link-local, protocol and documentation ranges, benchmarking, multicast, reserved and broadcast. */
    private val reservedV4 = listOf(
        v4(0, 0, 0, 0, bits = 8), v4(10, 0, 0, 0, bits = 8), v4(100, 64, 0, 0, bits = 10), v4(127, 0, 0, 0, bits = 8), v4(169, 254, 0, 0, bits = 16), v4(172, 16, 0, 0, bits = 12),
        v4(192, 0, 0, 0, bits = 24), v4(192, 0, 2, 0, bits = 24), v4(192, 88, 99, 0, bits = 24), v4(192, 168, 0, 0, bits = 16), v4(198, 18, 0, 0, bits = 15), v4(198, 51, 100, 0, bits = 24),
        v4(203, 0, 113, 0, bits = 24), v4(224, 0, 0, 0, bits = 4), v4(240, 0, 0, 0, bits = 4),
    )
    /** IPv6 blocks that are not ordinary public addresses: unspecified, loopback, local-use NAT64 (64:ff9b:1::/48, which can reach any IPv4 address), discard, documentation, Teredo, unique-local, link-local, site-local and multicast. */
    private val reservedV6 = listOf(
        v6("::", 128), v6("::1", 128), v6("64:ff9b:1::", 48), v6("100::", 64), v6("2001::", 32), v6("2001:db8::", 32), v6("fc00::", 7), v6("fe80::", 10), v6("fec0::", 10), v6("ff00::", 8),
    )

    fun isPublic(a: InetAddress): Boolean {
        if (a.isAnyLocalAddress || a.isLoopbackAddress || a.isLinkLocalAddress || a.isSiteLocalAddress || a.isMulticastAddress) return false
        val b = a.address
        return when (a) {
            is Inet4Address -> reservedV4.none { it.covers(b) }
            is Inet6Address -> {
                if (reservedV6.any { it.covers(b) }) return false
                // Addresses that carry an IPv4 address (::ffff:a.b.c.d, NAT64 64:ff9b::/96, 6to4 2002::/16) are judged by the IPv4 address inside.
                val inner = when {
                    (0 until 10).all { b[it] == 0.toByte() } && b[10] == 0xff.toByte() && b[11] == 0xff.toByte() -> b.copyOfRange(12, 16)
                    b[0] == 0x00.toByte() && b[1] == 0x64.toByte() && b[2] == 0xff.toByte() && b[3] == 0x9b.toByte() && (4 until 12).all { b[it] == 0.toByte() } -> b.copyOfRange(12, 16)
                    b[0] == 0x20.toByte() && b[1] == 0x02.toByte() -> b.copyOfRange(2, 6)
                    else -> null
                }
                inner == null || isPublic(InetAddress.getByAddress(inner))
            }
            else -> false
        }
    }
}

/**
 * Looks a name up through [delegate] (the app's own resolver, so App DNS still applies) and refuses it when any answer is not a public address. The connection then uses only the
 * addresses that were checked, TLS is still verified against the original name, and the check runs again for every redirect because every new connection looks the name up.
 */
class PublicOnlyDns(private val delegate: Dns) : Dns {
    override fun lookup(hostname: String): List<InetAddress> {
        val answers = delegate.lookup(hostname)
        if (answers.isEmpty() || answers.any { !AddonAddresses.isPublic(it) }) throw UnknownHostException("$hostname does not point to a public address")
        return answers
    }
}
