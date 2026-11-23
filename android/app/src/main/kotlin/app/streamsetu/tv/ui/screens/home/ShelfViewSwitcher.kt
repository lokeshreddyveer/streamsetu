package app.streamsetu.tv.ui.screens.home

import app.streamsetu.core.data.smartmix.ShelfView
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/**
 * The section-local switch of a ranking shelf ("All time | This week"). A tap changes only that shelf: the control moves at once, the choice is saved, and only that shelf is built (alone, never
 * committed, nothing invalidated); the other shelves, their order and Home's scroll stay as they are. Both views of a shelf are kept (key: shelf and view), so switching back builds nothing. A newer tap on the
 * same shelf cancels the older build, so a stale answer is never shown. [reset] is called when Home itself is rebuilt (a new day, a shuffle, a lock or profile change, a sync).
 */
class ShelfViewSwitcher(
    private val scope: CoroutineScope,
    private val save: (shelfId: String, view: ShelfView) -> Unit,
    private val build: suspend (shelfId: String, view: ShelfView) -> HomeViewModel.MixShelf?,
) {
    private val _overrides = MutableStateFlow<Map<String, HomeViewModel.MixShelf>>(emptyMap())
    val overrides: StateFlow<Map<String, HomeViewModel.MixShelf>> = _overrides
    private val cache = HashMap<String, HomeViewModel.MixShelf>()
    private val jobs = HashMap<String, Job>()
    var builds = 0; private set

    private fun key(id: String, v: ShelfView) = "$id|${v.wire}"

    fun reset() { jobs.values.forEach { it.cancel() }; jobs.clear(); cache.clear(); _overrides.value = emptyMap() }
    /** A shelf Home built (in its own view): kept, so switching to it later is instant. */
    fun remember(s: HomeViewModel.MixShelf) { s.view?.let { cache[key(s.id, it)] = s } }
    fun cached(id: String, v: ShelfView) = cache[key(id, v)]
    fun apply(base: List<HomeViewModel.MixShelf>, over: Map<String, HomeViewModel.MixShelf> = _overrides.value): List<HomeViewModel.MixShelf> = if (over.isEmpty()) base else base.map { over[it.id] ?: it }

    /** [current] is what the shelf shows now (so the control can move and the tiles stay until the new ones arrive). */
    fun switch(current: HomeViewModel.MixShelf?, shelfId: String, view: ShelfView) {
        save(shelfId, view)
        jobs.remove(shelfId)?.cancel()
        cached(shelfId, view)?.let { hit -> _overrides.value = _overrides.value + (shelfId to hit); return }
        current?.let { _overrides.value = _overrides.value + (shelfId to it.copy(view = view)) }
        jobs[shelfId] = scope.launch {
            val built = build(shelfId, view); builds++
            if (built != null) { cache[key(shelfId, view)] = built; _overrides.value = _overrides.value + (shelfId to built) }
        }
    }

    /** After Home has drawn: the other view of each switchable shelf, one at a time, so the first tap is instant too. */
    suspend fun warm(shelves: List<HomeViewModel.MixShelf>) {
        for (s in shelves) {
            val v = s.view ?: continue
            val other = if (v == ShelfView.WEEKLY) ShelfView.ALL_TIME else ShelfView.WEEKLY
            if (cached(s.id, other) != null) continue
            build(s.id, other)?.let { cache[key(s.id, other)] = it }
            builds++
        }
    }
}
