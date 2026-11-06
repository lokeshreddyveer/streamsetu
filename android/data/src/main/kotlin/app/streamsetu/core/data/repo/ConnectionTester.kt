package app.streamsetu.core.data.repo

import app.streamsetu.core.model.Source
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlin.coroutines.cancellation.CancellationException

/**
 * Testing a connection by hand: it is saved under ONE id for the whole setup (the same one for every Test, for Save as Draft and for the connection it becomes), signed in to, and read.
 *
 * What a Test leaves behind:
 *  - a connection that was never saved: nothing, when the Test fails, finds nothing to watch, or is cancelled (before, every press of Test made another saved connection with its login);
 *  - a connection the person saved as a draft, or one that already works: it stays, with the error noted. A working one keeps its counts, guide address and state.
 */
class ConnectionTester(private val sources: Store, private val read: suspend (sourceId: String) -> Counts) {
    interface Store {
        suspend fun get(id: String): Source?
        suspend fun add(source: Source, password: String?): Source
        suspend fun remove(id: String)
        suspend fun setError(id: String, message: String?)
    }

    data class Counts(val channels: Int, val movies: Int, val series: Int) { val total get() = channels + movies + series }

    sealed interface Result {
        data class Passed(val sourceId: String, val counts: Counts) : Result
        data class Failed(val message: String) : Result
    }

    /**
     * [id] is the connection's id for the whole setup. [typed] is what the form holds; for a connection that already exists only these typed fields change.
     * [prepare] runs after the connection is saved and before it is read (custom headers, certificate trust).
     */
    suspend fun test(id: String, typed: Source, password: String?, prepare: suspend (sourceId: String) -> Unit = {}): Result {
        require(id.isNotBlank()) { "a setup has one id from its first Test" }
        val existing = sources.get(id)
        val createdHere = existing == null
        val saved = sources.add(existing?.copy(name = typed.name, type = typed.type, address = typed.address, username = typed.username, userAgent = typed.userAgent) ?: typed.copy(id = id), password)
        try {
            prepare(saved.id)
            val counts = read(saved.id)
            if (counts.total == 0) return failed(saved.id, createdHere, "The sign-in worked but the provider returned nothing to watch. Check that the subscription is active.", "Nothing to watch")
            return Result.Passed(saved.id, counts)
        } catch (e: CancellationException) {
            if (createdHere) withContext(NonCancellable) { sources.remove(saved.id) }
            throw e
        } catch (e: Exception) {
            return failed(saved.id, createdHere, e.message ?: "The connection could not be read.", e.message?.take(200))
        }
    }

    private suspend fun failed(id: String, createdHere: Boolean, message: String, note: String?): Result {
        if (createdHere) sources.remove(id) else sources.setError(id, note)
        return Result.Failed(message)
    }
}
