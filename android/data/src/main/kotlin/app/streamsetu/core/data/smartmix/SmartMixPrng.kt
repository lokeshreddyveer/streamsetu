package app.streamsetu.core.data.smartmix

/** Source of unsigned 64-bit words; a stub of this proves the rejection branch of [uniform]. */
fun interface Rng64 {
    fun next(): ULong
}

/** FNV-1a, 64 bit, over raw bytes (integer only, identical on every platform). */
object Fnv1a64 {
    const val OFFSET: ULong = 0xcbf29ce484222325uL
    const val PRIME: ULong = 0x100000001b3uL

    fun hash(bytes: ByteArray): ULong {
        var h = OFFSET
        for (b in bytes) {
            h = h xor (b.toULong() and 0xFFuL)
            h *= PRIME
        }
        return h
    }

    fun hash(text: String): ULong = hash(text.toByteArray(Charsets.UTF_8))
}

/** SplitMix64 (unsigned wrapping arithmetic; Kotlin ULong wraps modulo 2^64). */
class SplitMix64(seed: ULong) : Rng64 {
    private var state: ULong = seed

    override fun next(): ULong {
        state += 0x9E3779B97F4A7C15uL
        var z = state
        z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9uL
        z = (z xor (z shr 27)) * 0x94D049BB133111EBuL
        return z xor (z shr 31)
    }
}

/** Unbiased value in [0, n): rejects the first 2^64 mod n values. n must be >= 1. */
fun Rng64.uniform(n: ULong): ULong {
    require(n >= 1uL) { "n must be >= 1" }
    val limit = (0uL - n) % n
    while (true) {
        val x = next()
        if (x >= limit) return x % n
    }
}

object SmartMixSeed {
    fun seedString(profileId: String, shelfId: String, dayKey: String, refreshCounter: Int): String =
        "smartmix1|$profileId|$shelfId|$dayKey|$refreshCounter"

    fun seed(profileId: String, shelfId: String, dayKey: String, refreshCounter: Int): ULong =
        Fnv1a64.hash(seedString(profileId, shelfId, dayKey, refreshCounter))

    fun rng(profileId: String, shelfId: String, dayKey: String, refreshCounter: Int): SplitMix64 =
        SplitMix64(seed(profileId, shelfId, dayKey, refreshCounter))
}
