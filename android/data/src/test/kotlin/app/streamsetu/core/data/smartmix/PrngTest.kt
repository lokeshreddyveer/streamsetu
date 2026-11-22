package app.streamsetu.core.data.smartmix

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Assume
import org.junit.Test
import java.io.File

class PrngTest {
    private fun hex(x: ULong) = x.toString(16).uppercase().padStart(16, '0')

    @Test fun contractVectors() {
        assertEquals(listOf("E220A8397B1DCDAF", "6E789E6AA1B965F4", "06C45D188009454F"), SplitMix64(0uL).let { r -> List(3) { hex(r.next()) } })
        assertEquals(listOf("910A2DEC89025CC1", "BEEB8DA1658EEC67"), SplitMix64(1uL).let { r -> List(2) { hex(r.next()) } })
        assertEquals("CBF29CE484222325", hex(Fnv1a64.hash(""))); assertEquals("AF63DC4C8601EC8C", hex(Fnv1a64.hash("a")))
        val seed = SmartMixSeed.seed("main", "hero", "2026-11-21", 0)
        assertEquals("EA146339CF956E5F", hex(seed))
        val r = SplitMix64(seed)
        assertEquals(listOf(600uL, 713uL, 122uL, 290uL, 566uL), List(5) { r.uniform(1000uL) })
    }
    @Test fun uniformRejectionBranchIsExercised() {
        val n = (1uL shl 63) + 1uL
        val limit = (0uL - n) % n
        assertTrue(limit > 0uL)
        val seq = ArrayDeque(listOf(0uL, limit - 1uL, limit + 5uL))
        var calls = 0
        val v = Rng64 { calls++; seq.removeFirst() }.uniform(n)
        assertEquals(3, calls); assertEquals((limit + 5uL) % n, v)
        assertEquals(0uL, SplitMix64(9uL).uniform(1uL))
    }
    @Test fun noModuloBiasOnSmallRange() {
        // n = 3 over 300k draws stays within 1% of uniform
        val r = SplitMix64(42uL); val c = IntArray(3)
        repeat(300_000) { c[r.uniform(3uL).toInt()]++ }
        for (x in c) assertTrue(x in 99_000..101_000)
    }
    @Test fun sharedPrngFixture() {
        val dir = FixtureFiles.dir(); Assume.assumeNotNull(dir)
        val j = Json.parseToJsonElement(File(dir, "prng.json").readText()).jsonObject
        for (e in j["fnv1a64"]!!.jsonArray) { val o = e.jsonObject; assertEquals(o["hex"]!!.jsonPrimitive.content, hex(Fnv1a64.hash(o["input"]!!.jsonPrimitive.content))) }
        for (e in j["splitmix64"]!!.jsonArray) {
            val o = e.jsonObject; val r = SplitMix64(o["seed"]!!.jsonPrimitive.content.toULong())
            assertEquals(o["hex"]!!.jsonArray.map { it.jsonPrimitive.content }, o["hex"]!!.jsonArray.map { hex(r.next()) })
        }
        val s = j["seedString"]!!.jsonObject
        assertEquals(s["value"]!!.jsonPrimitive.content, SmartMixSeed.seedString(s["profile"]!!.jsonPrimitive.content, s["shelf"]!!.jsonPrimitive.content, s["day"]!!.jsonPrimitive.content, s["counter"]!!.jsonPrimitive.int))
        for (e in j["uniform"]!!.jsonArray) {
            val o = e.jsonObject
            val vals = o["values"]!!.jsonArray.map { it.jsonPrimitive.content.toULong() }
            if (o.containsKey("seedString")) {
                val r = SplitMix64(Fnv1a64.hash(o["seedString"]!!.jsonPrimitive.content)); val n = o["n"]!!.jsonPrimitive.content.toULong()
                assertEquals(vals, vals.map { r.uniform(n) })
            } else if (o.containsKey("ns")) {
                val r = SplitMix64(o["splitmixSeed"]!!.jsonPrimitive.content.toULong()); val ns = o["ns"]!!.jsonArray.map { it.jsonPrimitive.content.toULong() }
                assertEquals(vals, ns.map { r.uniform(it) })
            } else {
                val r = SplitMix64(o["splitmixSeed"]!!.jsonPrimitive.content.toULong()); val n = o["n"]!!.jsonPrimitive.content.toULong()
                assertEquals(vals, vals.map { r.uniform(n) })
            }
        }
    }
}
