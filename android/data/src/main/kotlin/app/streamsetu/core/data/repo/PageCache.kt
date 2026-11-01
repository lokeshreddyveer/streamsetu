package app.streamsetu.core.data.repo

/**
 * A few recent first pages, each saved with the catalog revision it was read at. A page is reused only for exactly the same key (library, profile, restrictions, folder, sort) and the same
 * revision; a key of another security context is never looked at, and a revision that changed is a miss, so the page is read again. Four entries by default: a handful of folders or sorts,
 * not a store of the library.
 */
class PageCache<K : Any, V : Any>(private val capacity: Int = 4) {
    private data class Entry<V>(val revision: Any, val value: V)
    private val map = object : LinkedHashMap<K, Entry<V>>(capacity + 1, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<K, Entry<V>>) = size > capacity
    }

    @Synchronized fun get(key: K, revision: Any): V? = map[key]?.takeIf { it.revision == revision }?.value
    @Synchronized fun put(key: K, revision: Any, value: V) { map[key] = Entry(revision, value) }
    /** Drops every page for which [affected] is true (a source whose catalog was written, for instance). */
    @Synchronized fun invalidate(affected: (K) -> Boolean) { map.keys.removeAll { affected(it) } }
    @Synchronized fun clear() = map.clear()
    @get:Synchronized val size get() = map.size
}
