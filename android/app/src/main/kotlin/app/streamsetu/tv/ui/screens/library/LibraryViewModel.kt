package app.streamsetu.tv.ui.screens.library

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.streamsetu.core.model.*
import app.streamsetu.tv.AppContainer
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import javax.inject.Inject

/** Choosing, creating and managing libraries and connections. */
@HiltViewModel
class LibraryViewModel @Inject constructor(private val c: AppContainer) : ViewModel() {
    val entries: StateFlow<List<LibraryEntry>?> = c.library.entries.map<List<LibraryEntry>, List<LibraryEntry>?> { it }.stateIn(viewModelScope, SharingStarted.Eagerly, null)
    val lastUsedId: String? get() = c.library.lastUsedId

    fun open(entry: LibraryEntry, then: () -> Unit) = viewModelScope.launch { c.library.open(entry); then() }

    /** What a connection form holds while it is being filled in or tested. */
    data class Form(val name: String = "", val address: String = "", val user: String = "", val password: String = "")

    sealed interface Test {
        data object Idle : Test
        data object Running : Test
        data class Failed(val message: String) : Test
        data class Passed(val sourceId: String, val name: String, val channels: Int, val movies: Int, val series: Int) : Test
    }

    private val _test = MutableStateFlow<Test>(Test.Idle)
    val test: StateFlow<Test> = _test
    private var testing = false

    suspend fun draft(id: String): Pair<Source, String?>? = c.sources.get(id)?.let { it to c.sources.password(id) }

    /** Keeps what was typed so setup can be resumed later. A draft is never a working library. */
    fun saveDraft(type: SourceType, draftId: String?, f: Form, then: (String) -> Unit) = viewModelScope.launch {
        val saved = c.sources.add(
            Source(id = draftId.orEmpty(), name = f.name.ifBlank { f.address.trim().substringAfter("://").substringBefore('/').take(30).ifBlank { "Unfinished connection" } }, type = type,
                address = f.address.trim(), username = f.user.trim().ifBlank { null }, draft = true),
            f.password.trim().ifBlank { null },
        )
        then(saved.id)
    }

    /**
     * Tests the connection once, by hand: signs in, reads the catalog, and keeps the connection only when it holds something to watch.
     * Nothing retries by itself. A failure leaves the form as it was so the details can be corrected and tested again.
     */
    fun test(type: SourceType, draftId: String?, f: Form) {
        if (testing) return
        testing = true
        viewModelScope.launch {
            _test.value = Test.Running
            val label = f.name.ifBlank { f.address.trim().substringAfter("://").substringBefore('/').substringAfterLast('/').take(30).ifBlank { "My connection" } }
            val saved = c.sources.add(Source(id = draftId.orEmpty(), name = label, type = type, address = f.address.trim(), username = f.user.trim().ifBlank { null }, draft = true), f.password.trim().ifBlank { null })
            runCatching { c.syncWithGuide(saved.id) }
                .onSuccess { r ->
                    if (r.channels + r.movies + r.series == 0) _test.value = Test.Failed("The sign-in worked but the provider returned nothing to watch. Check that the subscription is active.").also { c.sources.setError(saved.id, "Nothing to watch") }
                    else _test.value = Test.Passed(saved.id, label, r.channels, r.movies, r.series)
                }
                .onFailure { _test.value = Test.Failed(it.message ?: "The connection could not be read.").also { _ -> c.sources.setError(saved.id, it.message?.take(200)) } }
            testing = false
        }
    }

    fun resetTest() { _test.value = Test.Idle }

    /** Discards a draft that was never finished. */
    fun discard(id: String) = viewModelScope.launch { c.sources.remove(id) }

    fun createCombined(name: String, sourceIds: List<String>, then: (String) -> Unit) = viewModelScope.launch { then(c.library.createCombined(name, sourceIds)) }
    fun updateCombined(entry: LibraryEntry, name: String, sourceIds: List<String>, then: () -> Unit) = viewModelScope.launch { c.library.rename(entry, name); c.library.setMembers(entry.id, sourceIds); then() }
    fun delete(entry: LibraryEntry, then: () -> Unit) = viewModelScope.launch {
        if (entry.kind == LibraryEntry.Kind.COMBINED) c.library.deleteCombined(entry) else entry.sourceIds.forEach { c.sources.remove(it) }
        then()
    }
    fun rename(entry: LibraryEntry, name: String) = viewModelScope.launch { c.library.rename(entry, name) }

    /** Re-reads a connection on request (the only time the chooser touches the network). */
    fun refresh(entry: LibraryEntry, then: (String?) -> Unit) = viewModelScope.launch {
        var error: String? = null
        entry.sourceIds.forEach { id -> runCatching { c.syncWithGuide(id) }.onFailure { error = it.message ?: "Could not read ${entry.name}." } }
        then(error)
    }

    suspend fun connections(): List<Source> = c.sources.all().filter { !it.draft }
    suspend fun memberIds(entry: LibraryEntry) = c.library.memberIds(entry)
}
