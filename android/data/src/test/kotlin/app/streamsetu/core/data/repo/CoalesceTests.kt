package app.streamsetu.core.data.repo

import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

class CoalesceTests {
    @Test fun aBurstBecomesTheFirstAndTheNewestValue() = runTest {
        val out = flow { for (i in 1..50) emit(i) }.coalesce(250).toList()
        assertEquals(50, out.last())
        assertEquals(1, out.first())
        assert(out.size <= 3)
    }

    @Test fun equalNeighboursAreDropped() = runTest {
        val out = flow { emit(1); emit(1); delay(1000); emit(1); emit(2) }.coalesce(100).toList()
        assertEquals(listOf(1, 2), out)
    }

    @Test fun spacedValuesAllPass() = runTest {
        val out = flow { emit(1); delay(500); emit(2); delay(500); emit(3) }.coalesce(100).toList()
        assertEquals(listOf(1, 2, 3), out)
    }
}
