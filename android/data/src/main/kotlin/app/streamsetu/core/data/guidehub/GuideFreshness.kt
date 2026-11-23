package app.streamsetu.core.data.guidehub

import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.LocalDateTime

enum class FreshLevel { FRESH, INFO, WARNING, ERROR }

data class FreshnessInput(
    val nowMs: Long, val enabled: Boolean = true, val windowEndMs: Long? = null, val lastSuccessMs: Long? = null, val lastAttemptFailed: Boolean = false,
    val refreshIntervalS: Long = 6 * 3600, val programmes: Int = 0,
)
data class Freshness(val level: FreshLevel, val key: String, val amount: Int?)

/** Guide freshness and the message key to show; a port of the Apple `GuideFreshness` (thresholds pinned by `epg/fixtures/freshness-cases.json`). */
object GuideFreshness {
    fun evaluate(i: FreshnessInput): Freshness {
        if (!i.enabled) return Freshness(FreshLevel.FRESH, "guide.off", null)
        val success = i.lastSuccessMs ?: return Freshness(if (i.lastAttemptFailed) FreshLevel.ERROR else FreshLevel.WARNING, "guide.neverUpdated", null)
        if (i.programmes == 0) return Freshness(FreshLevel.ERROR, "guide.empty", null)
        val end = i.windowEndMs ?: return Freshness(FreshLevel.ERROR, "guide.empty", null)
        val leftS = (end - i.nowMs) / 1000.0
        if (leftS < 0) return Freshness(FreshLevel.ERROR, "guide.noUpcoming", null)
        val ageS = (i.nowMs - success) / 1000.0
        val staleAfter = maxOf(3.0 * i.refreshIntervalS, 24.0 * 3600)
        val overdue = ageS > i.refreshIntervalS * 1.5 || i.lastAttemptFailed
        if (leftS < 3 * 3600) return Freshness(FreshLevel.WARNING, "guide.endsUnder3h", null)
        if (ageS > staleAfter) return Freshness(FreshLevel.WARNING, "guide.updatedLongAgo", (ageS / 86400).toInt())
        if (leftS < 12 * 3600 && overdue) return Freshness(FreshLevel.INFO, "guide.endsIn", (leftS / 3600).toInt())
        return Freshness(FreshLevel.FRESH, "guide.fresh", (leftS / 3600).toInt())
    }
}

/** XMLTV time stamps: an offset is authoritative; none means UTC unless the source says its times are local to a zone. Returns epoch milliseconds. */
object XmltvTime {
    private val tz = Regex("""^\s*(\d{8}(?:\d{2}(?:\d{2}(?:\d{2})?)?)?)\s*(Z|z|[+-]\d{2}:?\d{2}|[+-]\d{2}|UTC|GMT|UT)?\s*$""")

    fun parse(s: String, localZone: String? = null): Long? {
        val m = tz.matchEntire(s) ?: return null
        val d = m.groupValues[1]
        val y = d.substring(0, 4).toInt(); val mo = d.substring(4, 6).toInt(); val day = d.substring(6, 8).toInt()
        val h = if (d.length >= 10) d.substring(8, 10).toInt() else 0
        val mi = if (d.length >= 12) d.substring(10, 12).toInt() else 0
        val se = if (d.length >= 14) d.substring(12, 14).toInt() else 0
        if (y < 1970 || y >= 2200 || mo !in 1..12 || day !in 1..31 || h > 23 || mi > 59 || se > 60) return null
        val ldt = try { LocalDateTime.of(y, mo, day, h, mi, minOf(se, 59)) } catch (e: Exception) { return null }
        val z = m.groupValues[2]
        val off: Int? = when {
            z.isEmpty() -> null
            z.equals("Z", true) || z.uppercase() in setOf("UTC", "GMT", "UT") -> 0
            else -> {
                val sign = if (z[0] == '-') -1 else 1
                val digits = z.substring(1).replace(":", "")
                val hh = digits.substring(0, 2).toInt(); val mm = if (digits.length >= 4) digits.substring(2, 4).toInt() else 0
                if (hh > 14 || mm > 59) return null
                sign * (hh * 3600 + mm * 60)
            }
        }
        if (off != null) return ldt.toEpochSecond(java.time.ZoneOffset.UTC).minus(off) * 1000
        if (localZone != null) {
            val zone = try { ZoneId.of(localZone) } catch (e: Exception) { null }
            if (zone != null) return ZonedDateTime.ofLocal(ldt, zone, null).toInstant().toEpochMilli()
        }
        return ldt.toEpochSecond(java.time.ZoneOffset.UTC) * 1000
    }
    fun iso(ms: Long): String = Instant.ofEpochMilli(ms).toString()
}
