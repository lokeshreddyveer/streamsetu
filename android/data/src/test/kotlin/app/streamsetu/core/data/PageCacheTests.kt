package app.streamsetu.core.data

import app.streamsetu.core.data.repo.PageCache
import org.junit.Assert.*
import org.junit.Test

class PageCacheTests {
    private data class Key(val library: String, val profile: String, val folder: String)

    @Test fun theSameKeyAndRevisionIsAHit() {
        val c = PageCache<Key, List<Int>>(); val k = Key("lib", "me", "all")
        assertNull(c.get(k, "r1")); c.put(k, "r1", listOf(1, 2, 3))
        assertEquals(listOf(1, 2, 3), c.get(k, "r1"))
    }

    @Test fun aChangedCatalogRevisionIsAMissSoThePageIsReadAgain() {
        val c = PageCache<Key, List<Int>>(); val k = Key("lib", "me", "all")
        c.put(k, "r1", listOf(1)); assertNull(c.get(k, "r2"))
    }

    @Test fun anotherProfileOrLibraryNeverSeesThePageOfThisOne() {
        val c = PageCache<Key, List<Int>>(); c.put(Key("lib", "me", "all"), "r1", listOf(1))
        assertNull(c.get(Key("lib", "kids", "all"), "r1")); assertNull(c.get(Key("other", "me", "all"), "r1"))
    }

    @Test fun onlyTheFourMostRecentlyUsedPagesAreKept() {
        val c = PageCache<Key, List<Int>>(4)
        (1..5).forEach { c.put(Key("l", "p", "f$it"), "r", listOf(it)) }
        assertEquals(4, c.size); assertNull(c.get(Key("l", "p", "f1"), "r")); assertNotNull(c.get(Key("l", "p", "f5"), "r"))
        c.get(Key("l", "p", "f2"), "r"); c.put(Key("l", "p", "f6"), "r", listOf(6))          // f2 was used, so f3 (not f2) is the one that goes
        assertNotNull(c.get(Key("l", "p", "f2"), "r")); assertNull(c.get(Key("l", "p", "f3"), "r"))
    }

    @Test fun invalidatingASourceDropsOnlyItsPages() {
        val c = PageCache<Key, List<Int>>(); c.put(Key("a", "p", "x"), "r", listOf(1)); c.put(Key("b", "p", "x"), "r", listOf(2))
        c.invalidate { it.library == "a" }
        assertNull(c.get(Key("a", "p", "x"), "r")); assertNotNull(c.get(Key("b", "p", "x"), "r"))
    }
}
