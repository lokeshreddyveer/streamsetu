package app.streamsetu.core.data

import app.streamsetu.core.data.repo.ConnectionTester
import app.streamsetu.core.data.repo.ConnectionTester.Counts
import app.streamsetu.core.data.repo.ConnectionTester.Result
import app.streamsetu.core.model.Source
import app.streamsetu.core.model.SourceType
import app.streamsetu.core.model.SyncStatus
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** The saved connections and their logins, in memory: what a Test does to them is visible here. */
private class FakeStore : ConnectionTester.Store {
    val rows = LinkedHashMap<String, Source>()
    val passwords = HashMap<String, String>()
    var adds = 0
    override suspend fun get(id: String) = rows[id]
    override suspend fun add(source: Source, password: String?): Source {
        adds++; val s = if (source.id.isBlank()) source.copy(id = "generated-$adds") else source
        rows[s.id] = s; if (!password.isNullOrEmpty()) passwords[s.id] = password; return s
    }
    override suspend fun remove(id: String) { rows.remove(id); passwords.remove(id) }
    override suspend fun setError(id: String, message: String?) { rows[id]?.let { rows[id] = it.copy(lastError = message, status = SyncStatus.FAILED) } }
}

class ConnectionTesterTests {
    private fun typed(name: String = "Home", address: String = "http://host:8080") = Source(id = "", name = name, type = SourceType.XTREAM, address = address, username = "bob", draft = true)
    private fun run(b: suspend () -> Unit) = runBlocking { b() }

    @Test fun repeatedTestsOfANewConnectionUseOneSavedConnection() = run {
        val store = FakeStore(); var attempts = 0
        val tester = ConnectionTester(store) { attempts++; if (attempts < 3) throw IllegalStateException("wrong password") else Counts(10, 0, 0) }
        assertTrue(tester.test("setup-1", typed(), "pw1") is Result.Failed)
        assertTrue(tester.test("setup-1", typed(), "pw2") is Result.Failed)
        val last = tester.test("setup-1", typed(), "pw3")
        assertEquals("one id from the first Test to the last", Result.Passed("setup-1", Counts(10, 0, 0)), last)
        assertEquals(listOf("setup-1"), store.rows.keys.toList())
        assertEquals("pw3", store.passwords["setup-1"])
    }

    @Test fun aFailedTestOfANewConnectionLeavesNothingBehind() = run {
        val store = FakeStore()
        val tester = ConnectionTester(store) { throw IllegalStateException("could not sign in") }
        val r = tester.test("setup-1", typed(), "secret")
        assertEquals("could not sign in", (r as Result.Failed).message)
        assertTrue("no saved connection", store.rows.isEmpty())
        assertTrue("and no saved login", store.passwords.isEmpty())
    }

    @Test fun aConnectionThatReturnsNothingToWatchLeavesNothingBehindEither() = run {
        val store = FakeStore()
        val tester = ConnectionTester(store) { Counts(0, 0, 0) }
        assertTrue(tester.test("setup-1", typed(), "pw") is Result.Failed)
        assertTrue(store.rows.isEmpty() && store.passwords.isEmpty())
    }

    @Test fun aCancelledTestOfANewConnectionLeavesNothingBehind() = run {
        val store = FakeStore()
        val tester = ConnectionTester(store) { throw CancellationException("cancelled by the person") }
        try { tester.test("setup-1", typed(), "pw"); fail("cancellation must propagate") } catch (e: CancellationException) { /* expected */ }
        assertTrue(store.rows.isEmpty() && store.passwords.isEmpty())
    }

    @Test fun aFailedTestKeepsAConnectionTheyHadSavedAsADraft() = run {
        val store = FakeStore()
        store.add(typed().copy(id = "setup-1"), "pw")                                              // Save as Draft
        val tester = ConnectionTester(store) { throw IllegalStateException("provider is down") }
        assertTrue(tester.test("setup-1", typed(), "pw") is Result.Failed)
        val kept = store.rows["setup-1"]; assertNotNull("the draft the person saved stays", kept); kept!!
        assertEquals("provider is down", kept.lastError)
        assertTrue(kept.draft)
        assertEquals("pw", store.passwords["setup-1"])
    }

    @Test fun aSuccessfulTestMakesTheDraftTheRealConnectionUnderTheSameId() = run {
        val store = FakeStore()
        store.add(typed().copy(id = "setup-1"), "pw")
        val tester = ConnectionTester(store) { id ->
            store.rows[id] = store.rows.getValue(id).copy(draft = false, channelCount = 12, status = SyncStatus.OK)      // what the catalog write does
            Counts(12, 0, 0)
        }
        val r = tester.test("setup-1", typed(name = "Renamed"), "pw")
        assertEquals(Result.Passed("setup-1", Counts(12, 0, 0)), r)
        assertEquals(1, store.rows.size)
        val s = store.rows.getValue("setup-1")
        assertFalse(s.draft); assertEquals("Renamed", s.name)
    }

    @Test fun testingAWorkingConnectionKeepsItsCountsGuideAndStateEvenWhenTheTestFails() = run {
        val store = FakeStore()
        store.rows["conn-1"] = Source(id = "conn-1", name = "Old", type = SourceType.XTREAM, address = "http://old", username = "bob", epgUrl = "http://guide", lastSyncAt = 99, status = SyncStatus.OK,
            draft = false, channelCount = 500, movieCount = 7, seriesCount = 3)
        val tester = ConnectionTester(store) { throw IllegalStateException("temporarily unreachable") }
        assertTrue(tester.test("conn-1", typed(name = "Edited", address = "http://new"), null) is Result.Failed)
        val s = store.rows.getValue("conn-1")
        assertEquals("Edited", s.name); assertEquals("http://new", s.address)                      // what was typed
        assertEquals("http://guide", s.epgUrl); assertEquals(500, s.channelCount); assertEquals(99L, s.lastSyncAt)
        assertFalse("still a real connection, not demoted to a draft", s.draft)
    }

    @Test fun aSetupAbandonedBeforeAnyTestSavesNothing() = run {
        val store = FakeStore()
        ConnectionTester(store) { Counts(1, 0, 0) }                                                // the screen was opened and left: no call is made
        assertTrue(store.rows.isEmpty()); assertNull(store.rows["setup-1"])
    }

    @Test fun aBlankIdIsRefusedSoEveryTestHasOne() {
        val tester = ConnectionTester(FakeStore()) { Counts(1, 0, 0) }
        try { run { tester.test("", typed(), null) }; fail("must refuse") } catch (e: IllegalArgumentException) { /* expected */ }
    }
}
