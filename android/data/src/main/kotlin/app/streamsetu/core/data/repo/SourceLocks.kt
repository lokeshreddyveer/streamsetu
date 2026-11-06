package app.streamsetu.core.data.repo

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.concurrent.ConcurrentHashMap

/** A refresh that stopped because its connection is being removed. There is nothing to report for a connection that is going away. */
class SourceRemovedException(sourceId: String) : RuntimeException("The connection $sourceId was removed.")

/**
 * One lock per connection, shared by everything that writes or deletes that connection's catalog (a refresh, removing it, clearing an add-on's cache), so none of them can interleave:
 * a refresh writes in many short steps, and a removal that did not wait for it left the refresh adding rows for a connection that no longer existed.
 */
object SourceLocks {
    private val locks = ConcurrentHashMap<String, Mutex>()
    private val removing: MutableSet<String> = java.util.Collections.newSetFromMap(ConcurrentHashMap<String, Boolean>())          // not newKeySet(): that needs Android 7

    fun of(sourceId: String): Mutex = locks.getOrPut(sourceId) { Mutex() }

    /** True while the connection is being removed: a refresh checks this between its steps and stops. */
    fun isRemoving(sourceId: String) = sourceId in removing

    /** Runs [block] once any refresh of the connection has stopped (it stops at its next step, within tens of milliseconds) and holds the lock while it runs. */
    suspend fun <T> removing(sourceId: String, block: suspend () -> T): T {
        removing += sourceId
        try { return of(sourceId).withLock { block() } } finally { removing -= sourceId }
    }
}
