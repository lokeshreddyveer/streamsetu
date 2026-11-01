package app.streamsetu.core.data.repo

import android.content.SharedPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Who may see what in Search, and what Search remembers for whom. */
class SearchScopeTests {
    // ---- the context word: anything that changes who may see what must change it ----
    private fun key(profile: String = "p1", sources: List<String> = listOf("a", "b"), adult: Boolean = false, locked: List<String> = emptyList(), hidden: List<String> = emptyList()) =
        SearchContext.key(profile, sources, adult, locked, hidden)

    @Test fun theSameWordsMeanTheSamePerson() { assertEquals(key(), key()) }
    @Test fun theOrderOfSourcesAndFoldersDoesNotMatter() {
        assertEquals(key(sources = listOf("a", "b")), key(sources = listOf("b", "a")))
        assertEquals(key(locked = listOf("f1", "f2")), key(locked = listOf("f2", "f1")))
    }
    @Test fun anotherProfileClearsWhatWasOnScreen() { assertNotEquals(key(profile = "p1"), key(profile = "p2")) }
    @Test fun anotherLibraryClearsWhatWasOnScreen() {
        assertNotEquals(key(sources = listOf("a")), key(sources = listOf("a", "b")))
        assertNotEquals(key(sources = listOf("a")), key(sources = listOf("b")))
    }
    @Test fun lockingAFolderAgainRemovesItsResults() { assertNotEquals(key(locked = emptyList()), key(locked = listOf("adult"))) }
    @Test fun unlockingChangesTheWordToo() { assertNotEquals(key(locked = listOf("adult")), key(locked = emptyList())) }
    @Test fun hidingAChannelOrTheAdultSwitchChangesIt() {
        assertNotEquals(key(hidden = emptyList()), key(hidden = listOf("c9")))
        assertNotEquals(key(adult = false), key(adult = true))
    }

    // ---- history: kept per profile and library, never shared ----
    private class MemPrefs : SharedPreferences {
        val m = HashMap<String, String>()
        override fun getAll(): MutableMap<String, *> = m
        override fun getString(k: String, d: String?) = m[k] ?: d
        override fun getStringSet(k: String, d: MutableSet<String>?) = d
        override fun getInt(k: String, d: Int) = d
        override fun getLong(k: String, d: Long) = d
        override fun getFloat(k: String, d: Float) = d
        override fun getBoolean(k: String, d: Boolean) = d
        override fun contains(k: String) = m.containsKey(k)
        override fun registerOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) {}
        override fun unregisterOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) {}
        override fun edit(): SharedPreferences.Editor = object : SharedPreferences.Editor {
            val pending = HashMap<String, String?>()
            override fun putString(k: String, v: String?) = apply { pending[k] = v }
            override fun remove(k: String) = apply { pending[k] = null }
            override fun clear() = apply { m.clear() }
            override fun commit(): Boolean { apply(); return true }
            override fun apply() { for ((k, v) in pending) if (v == null) m.remove(k) else m[k] = v }
            override fun putStringSet(k: String, v: MutableSet<String>?) = this
            override fun putInt(k: String, v: Int) = this
            override fun putLong(k: String, v: Long) = this
            override fun putFloat(k: String, v: Float) = this
            override fun putBoolean(k: String, v: Boolean) = this
        }
    }

    private fun history(prefs: SharedPreferences, who: () -> String) = SearchHistory(prefs).also { it.contextOf = who }

    @Test fun anotherProfileNeverSeesWordsTypedByAnother() {
        val prefs = MemPrefs(); var who = "kid|lib1"
        val h = history(prefs) { who }
        h.rememberIn("ALL", "peppa pig")
        assertEquals(listOf("peppa pig"), h.recentIn("ALL"))
        who = "dad|lib1"
        assertTrue(h.recentIn("ALL").isEmpty())
    }
    @Test fun anotherLibraryHasItsOwnHistory() {
        val prefs = MemPrefs(); var who = "p1|libA"
        val h = history(prefs) { who }
        h.rememberIn("MOVIES", "inception")
        who = "p1|libB"
        assertTrue(h.recentIn("MOVIES").isEmpty())
        who = "p1|libA"
        assertEquals(listOf("inception"), h.recentIn("MOVIES"))
    }
    @Test fun eachScreenKeepsItsOwnWords() {
        val h = history(MemPrefs()) { "p1|lib" }
        h.rememberIn("MOVIES", "inception"); h.rememberIn("LIVE", "bbc")
        assertEquals(listOf("inception"), h.recentIn("MOVIES"))
        assertEquals(listOf("bbc"), h.recentIn("LIVE"))
    }
    @Test fun theLastTypedWordsAreForgottenWhenTheContextChanges() {
        var who = "p1|lib"; val h = history(MemPrefs()) { who }
        h.setLastIn("ALL", "biggboss")
        assertEquals("biggboss", h.lastIn("ALL"))
        who = "p2|lib"; h.contextChanged()
        assertEquals("", h.lastIn("ALL"))
    }
    @Test fun removingAProfileRemovesItsSearchesEverywhere() {
        val prefs = MemPrefs(); var who = "p1|libA"
        val h = history(prefs) { who }
        h.rememberIn("ALL", "secret"); h.remember("secret")
        who = "p1|libB"; h.rememberIn("ALL", "also secret")
        who = "p2|libA"; h.rememberIn("ALL", "keep me")
        h.forgetProfile("p1")
        who = "p1|libA"; assertTrue(h.recentIn("ALL").isEmpty())
        who = "p1|libB"; assertTrue(h.recentIn("ALL").isEmpty())
        who = "p2|libA"; assertEquals(listOf("keep me"), h.recentIn("ALL"))
    }
    @Test fun veryShortWordsAreNotRemembered() {
        val h = history(MemPrefs()) { "p1|lib" }
        h.rememberIn("ALL", "a"); assertTrue(h.recentIn("ALL").isEmpty())
    }
    @Test fun theSameWordIsKeptOnceNewestFirst() {
        val h = history(MemPrefs()) { "p1|lib" }
        h.rememberIn("ALL", "one"); h.rememberIn("ALL", "two"); h.rememberIn("ALL", "ONE")
        assertEquals(listOf("ONE", "two"), h.recentIn("ALL"))
    }
}
