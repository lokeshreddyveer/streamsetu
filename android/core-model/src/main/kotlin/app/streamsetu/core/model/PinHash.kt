package app.streamsetu.core.model

import java.security.MessageDigest
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * How a PIN is kept on the device. One SHA-256 pass is far too cheap for a number of four to eight digits: anyone holding a copy of the database or a backup could try every PIN
 * in seconds. A PIN is stored as PBKDF2-HMAC-SHA256, a deliberately slow derivation, with the number of rounds written into the stored text so it can be raised later:
 *
 *     pbkdf2-sha256$<rounds>$<64 hex digits>
 *
 * The rounds are measured on the device so one check takes about a quarter of a second (a phone does far more than a Fire TV Stick). A PIN stored the old way (64 hex digits, salt
 * and PIN hashed once) is still accepted, and is stored again in the new form the first time the right PIN is entered. Wrong tries are throttled separately ([PinThrottle]).
 * It is the same format and the same numbers as the Mac and iPhone apps. The derivation is written out with HMAC so it works on every Android version this app supports.
 */
object PinHash {
    const val SCHEME = "pbkdf2-sha256"
    const val MIN_ROUNDS = 60_000
    const val MAX_ROUNDS = 600_000
    private const val TARGET_MS = 250.0
    private const val MAX_ACCEPTED_ROUNDS = 10_000_000

    enum class Check { WRONG, RIGHT, RIGHT_BUT_OLD }

    /** PBKDF2-HMAC-SHA256 of the PIN's digits. [length] is 32 bytes unless a test asks for more. */
    fun derive(pin: String, salt: ByteArray, rounds: Int, length: Int = 32): ByteArray {
        require(pin.isNotEmpty() && rounds > 0)
        val mac = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(pin.toByteArray(Charsets.UTF_8), "HmacSHA256")) }
        val out = ByteArray(length)
        var block = 1
        var pos = 0
        while (pos < length) {
            mac.update(salt)
            mac.update(byteArrayOf((block ushr 24).toByte(), (block ushr 16).toByte(), (block ushr 8).toByte(), block.toByte()))
            var u = mac.doFinal()
            val t = u.copyOf()
            for (i in 1 until rounds) {
                u = mac.doFinal(u)
                for (j in t.indices) t[j] = (t[j].toInt() xor u[j].toInt()).toByte()
            }
            val n = minOf(t.size, length - pos)
            System.arraycopy(t, 0, out, pos, n)
            pos += n; block++
        }
        return out
    }

    /** The number of rounds that makes one check take about a quarter of a second on this device, between [MIN_ROUNDS] and [MAX_ROUNDS]. Measured once per launch. */
    val calibratedRounds: Int by lazy {
        val probe = 20_000
        val start = System.nanoTime()
        derive("0000", "calibrate".toByteArray(), probe)
        val ms = maxOf((System.nanoTime() - start) / 1_000_000.0, 0.5)
        (probe * TARGET_MS / ms).toInt().coerceIn(MIN_ROUNDS, MAX_ROUNDS)
    }

    /** The text to store for this PIN and salt. */
    fun make(pin: String, salt: ByteArray, rounds: Int = calibratedRounds): String = "$SCHEME$$rounds$" + hex(derive(pin, salt, rounds))

    /** Whether the PIN matches what was stored. [Check.RIGHT_BUT_OLD] means it matches but the stored text is the old single-pass form and should be replaced with [make]. */
    fun verify(pin: String, salt: ByteArray, stored: String): Check {
        val parts = stored.split('$')
        if (parts.size == 3 && parts[0] == SCHEME) {
            val rounds = parts[1].toIntOrNull()?.takeIf { it in 1..MAX_ACCEPTED_ROUNDS } ?: return Check.WRONG
            return if (equal(hex(derive(pin, salt, rounds)), parts[2])) Check.RIGHT else Check.WRONG
        }
        if (parts.size == 1) {
            val legacy = hex(MessageDigest.getInstance("SHA-256").digest(salt + pin.toByteArray(Charsets.UTF_8)))
            return if (equal(legacy, stored)) Check.RIGHT_BUT_OLD else Check.WRONG
        }
        return Check.WRONG
    }

    fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }

    /** Compared in full whatever the first difference, so timing says nothing about the PIN. */
    private fun equal(a: String, b: String) = MessageDigest.isEqual(a.toByteArray(), b.toByteArray())
}
