package app.streamsetu.core.parse

import org.junit.Assert.assertEquals
import org.junit.Test

class XmltvTimeTests {
    @Test fun utcWithoutZone() = assertEquals(1_760_380_200_000L, XmltvParser.parseTime("20251013183000"))
    @Test fun explicitUtcZone() = assertEquals(1_760_380_200_000L, XmltvParser.parseTime("20251013183000 +0000"))
    @Test fun positiveOffsetIsEarlierInUtc() = assertEquals(1_760_380_200_000L - 2 * 3600_000, XmltvParser.parseTime("20251013183000 +0200"))
    @Test fun negativeOffsetIsLaterInUtc() = assertEquals(1_760_380_200_000L + 5 * 3600_000 + 1800_000, XmltvParser.parseTime("20251013183000 -0530"))
    @Test fun withoutSeconds() = assertEquals(1_760_380_200_000L - 30_000 + 30_000, XmltvParser.parseTime("202510131830"))
    @Test fun leapDay() = assertEquals(1_709_164_800_000L, XmltvParser.parseTime("20240229000000 +0000"))
    @Test fun garbageIsZero() { assertEquals(0L, XmltvParser.parseTime("")); assertEquals(0L, XmltvParser.parseTime("soon")) }
}
