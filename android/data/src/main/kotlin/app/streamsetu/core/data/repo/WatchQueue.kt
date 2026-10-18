package app.streamsetu.core.data.repo

import app.streamsetu.core.model.ContentKind
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** A movie or series lined up to play. */
data class QueuedTitle(val kind: ContentKind, val id: String, val title: String)

/** Where the line is kept between launches: one string. */
interface QueueStore { fun read(): String; fun write(value: String) }

/**
 * The titles lined up to play after the one on screen: movies, and series (which play the episode a person would watch next). A title added twice
 * stays once. The line is kept between launches.
 */
class WatchQueue(private val store: QueueStore) {
    private val _items = MutableStateFlow(load())
    val items: StateFlow<List<QueuedTitle>> = _items

    private fun load(): List<QueuedTitle> = store.read().lines().mapNotNull { line ->
        val p = line.split('\t')
        if (p.size < 3) return@mapNotNull null
        val kind = ContentKind.entries.firstOrNull { it.name == p[0] }?.takeIf { it == ContentKind.MOVIE || it == ContentKind.SERIES } ?: return@mapNotNull null
        QueuedTitle(kind, p[1], p.drop(2).joinToString(" "))
    }

    private fun save(list: List<QueuedTitle>) {
        _items.value = list
        store.write(list.joinToString("\n") { "${it.kind.name}\t${it.id}\t${it.title.replace('\t', ' ').replace('\n', ' ')}" })
    }

    fun contains(id: String) = _items.value.any { it.id == id }

    /** Puts a title at the end of the line, or at the front when [next] (it plays as soon as the current one ends). */
    fun add(title: QueuedTitle, next: Boolean = false) {
        val rest = _items.value.filter { it.id != title.id }
        save(if (next) listOf(title) + rest else rest + title)
    }

    fun remove(id: String) = save(_items.value.filter { it.id != id })
    fun clear() = save(emptyList())

    /** Takes the title at the front of the line, or null when the line is empty. */
    fun popNext(): QueuedTitle? {
        val first = _items.value.firstOrNull() ?: return null
        save(_items.value.drop(1))
        return first
    }
}
