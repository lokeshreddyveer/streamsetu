package app.streamsetu.core.data

import app.streamsetu.core.data.repo.lockedFrom
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Every list (Movies, Series, Live TV, Home, the Guide) is read again from the database whenever this filter says something. Its clock ticks every few seconds so a folder
 * can lock again on time; a tick that changes nothing must not make every open list start over (on a slow box it never got to finish).
 */
class FolderLocksTests {
    private val locked = MutableStateFlow(listOf("adult"))
    private val unlocked = MutableStateFlow<Set<String>>(emptySet())
    private val ticks = MutableSharedFlow<Unit>(extraBufferCapacity = 64)
    private val seen = ArrayList<Set<String>>()
    private val scope = CoroutineScope(Dispatchers.Unconfined)

    private fun collect() { scope.launch { lockedFrom(locked, unlocked, ticks).collect { seen += it } } }

    @Test fun aClockTickThatChangesNothingDoesNotMakeAListStartOver() = runBlocking {
        collect(); ticks.emit(Unit)
        repeat(10) { ticks.emit(Unit) }
        assertEquals("the first answer, then nothing for ten ticks", listOf(setOf("adult")), seen)
        scope.cancel()
    }

    @Test fun unlockingAFolderIsStillReported() = runBlocking {
        collect(); ticks.emit(Unit)
        unlocked.value = setOf("adult")
        assertEquals(listOf(setOf("adult"), emptySet()), seen)
        scope.cancel()
    }

    @Test fun lockingAnotherFolderIsStillReported() = runBlocking {
        collect(); ticks.emit(Unit)
        locked.value = listOf("adult", "kids")
        assertEquals(listOf(setOf("adult"), setOf("adult", "kids")), seen)
        scope.cancel()
    }

    @Test fun aFolderWhoseTimeRanOutIsReportedAtTheNextTick() = runBlocking {
        collect(); ticks.emit(Unit)
        unlocked.value = setOf("adult")           // opened
        unlocked.value = emptySet()               // the policy took it back (the clock noticed on a tick)
        ticks.emit(Unit)
        assertEquals(listOf(setOf("adult"), emptySet(), setOf("adult")), seen)
        scope.cancel()
    }
}
