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
    data class Form(val name: String = "", val address: String = "", val user: String = "", val password: String = "", val userAgent: String = "", val headers: String = "", val trustCertificate: Boolean = false)

    sealed interface Test {
        data object Idle : Test
        data object Running : Test
        data class Failed(val message: String) : Test
        data class Passed(val sourceId: String, val name: String, val channels: Int, val movies: Int, val series: Int) : Test
    }

    private val _test = MutableStateFlow<Test>(Test.Idle)
    val test: StateFlow<Test> = _test
    private var testing = false

    fun headersFor(id: String): String = c.resolver.customHeadersText(id)
    fun trustsCertificate(id: String): Boolean = c.resolver.allowsSelfSignedTls(id)

    suspend fun draft(id: String): Pair<Source, String?>? = c.sources.get(id)?.let { it to c.sources.password(id) }

    /** Keeps what was typed so setup can be resumed later. A draft is never a working library. */
    fun saveDraft(type: SourceType, draftId: String?, f: Form, then: (String) -> Unit) = viewModelScope.launch {
        val saved = c.sources.add(
            Source(id = draftId.orEmpty(), name = f.name.ifBlank { f.address.trim().substringAfter("://").substringBefore('/').take(30).ifBlank { "Unfinished connection" } }, type = type,
                address = f.address.trim(), username = f.user.trim().ifBlank { null }, draft = true, userAgent = f.userAgent.trim().ifBlank { null }),
            f.password.trim().ifBlank { null },
        )
        c.resolver.setCustomHeaders(saved.id, f.headers); c.resolver.setAllowsSelfSignedTls(saved.id, f.trustCertificate)
        then(saved.id)
    }

    /**
     * Tests the connection once, by hand: signs in, reads the catalog, and keeps the connection only when it holds something to watch.
     * Nothing retries by itself. A failure leaves the form as it was so the details can be corrected and tested again.
     */
    private var testJob: kotlinx.coroutines.Job? = null

    private val tester = app.streamsetu.core.data.repo.ConnectionTester(
        object : app.streamsetu.core.data.repo.ConnectionTester.Store {
            override suspend fun get(id: String) = c.sources.get(id)
            override suspend fun add(source: Source, password: String?) = c.sources.add(source, password)
            override suspend fun remove(id: String) = c.sources.remove(id)
            override suspend fun setError(id: String, message: String?) = c.sources.setError(id, message)
        },
        read = { id -> c.syncWithGuide(id).let { app.streamsetu.core.data.repo.ConnectionTester.Counts(it.channels, it.movies, it.series) } },
    )

    /** The id a new connection keeps from its first Test to the connection it becomes (the setup screen asks for it once). */
    fun newSetupId(): String = java.util.UUID.randomUUID().toString()

    fun test(type: SourceType, draftId: String?, f: Form) {
        if (testing) return
        testing = true
        testJob = viewModelScope.launch {
            _test.value = Test.Running
            val label = f.name.ifBlank { f.address.trim().substringAfter("://").substringBefore('/').substringAfterLast('/').take(30).ifBlank { "My connection" } }
            val id = draftId?.takeIf { it.isNotBlank() } ?: newSetupId()
            val typed = Source(id = id, name = label, type = type, address = f.address.trim(), username = f.user.trim().ifBlank { null }, draft = true, userAgent = f.userAgent.trim().ifBlank { null })
            try {
                when (val r = tester.test(id, typed, f.password.trim().ifBlank { null }) { sid -> c.resolver.setCustomHeaders(sid, f.headers); c.resolver.setAllowsSelfSignedTls(sid, f.trustCertificate) }) {
                    is app.streamsetu.core.data.repo.ConnectionTester.Result.Passed -> { _test.value = Test.Passed(r.sourceId, label, r.counts.channels, r.counts.movies, r.counts.series); app.streamsetu.tv.UISound.play(app.streamsetu.tv.UISoundEvent.SUCCESS) }
                    is app.streamsetu.core.data.repo.ConnectionTester.Result.Failed -> { app.streamsetu.tv.UISound.play(app.streamsetu.tv.UISoundEvent.ERROR); _test.value = Test.Failed(r.message) }
                }
            } finally { testing = false }
        }
    }

    /** Stops a test that is taking too long. The form is left as it was, ready to be corrected or tested again. */
    fun cancelTest() { testJob?.cancel(); testJob = null; testing = false; _test.value = Test.Idle }

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
