package app.streamsetu.tv

import app.streamsetu.core.sync.SyncProgress
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged

/**
 * Whether the open library is still being filled: a playlist read is running, or the identity fill that follows it. Screens that list titles use it to show "being filled" with progress
 * instead of an empty message while the first rows are still arriving. Reads may overlap, so they are counted.
 */
class LibraryFill {
    private val syncs = MutableStateFlow(0)
    private val identity = MutableStateFlow(false)
    private val _progress = MutableStateFlow<SyncProgress?>(null)
    /** The stage of the read that is running, or null. */
    val progress: StateFlow<SyncProgress?> = _progress

    /** True while a read or the identity fill is running. */
    val filling: Flow<Boolean> = combine(syncs, identity) { n, i -> n > 0 || i }.distinctUntilChanged()
    val fillingNow: Boolean get() = syncs.value > 0 || identity.value

    fun syncStarted() { syncs.value = syncs.value + 1 }
    fun syncEnded() { syncs.value = (syncs.value - 1).coerceAtLeast(0); if (syncs.value == 0) _progress.value = null }
    fun report(p: SyncProgress) { _progress.value = p }
    fun identityRunning(on: Boolean) { identity.value = on }
}
