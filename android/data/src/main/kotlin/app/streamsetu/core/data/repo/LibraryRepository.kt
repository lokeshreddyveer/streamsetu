package app.streamsetu.core.data.repo

import android.content.Context
import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.db.LibraryEntity
import app.streamsetu.core.data.db.LibraryMemberEntity
import app.streamsetu.core.model.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.*
import java.util.UUID

/**
 * The libraries the person can open: each connection on its own, and combined libraries made of several connections.
 * A combined library copies nothing; it is a list of member connections, and every screen reads those members' records together.
 * The library chosen at launch is the one every catalog query is limited to (see [sourceIds]).
 */
class LibraryRepository(private val db: AppDatabase, context: Context, scope: CoroutineScope) {
    private val prefs = context.getSharedPreferences("library", Context.MODE_PRIVATE)
    private val dao get() = db.libraries()

    val entries: Flow<List<LibraryEntry>> = combine(db.sources().observe(), dao.observe(), dao.members()) { sources, libs, members ->
        val bySource = sources.map { it.toModel() }.associateBy { it.id }
        val combined = libs.map { l ->
            val ids = members.filter { it.libraryId == l.id }.map { it.sourceId }.filter { bySource[it]?.draft == false }
            val ms = ids.mapNotNull { bySource[it] }
            LibraryEntry(
                id = "lib:${l.id}", name = l.name, kind = LibraryEntry.Kind.COMBINED, sourceIds = ids, typeLabel = "Combined library · ${ms.size} connection${if (ms.size == 1) "" else "s"}",
                channelCount = ms.sumOf { it.channelCount }, movieCount = ms.sumOf { it.movieCount }, seriesCount = ms.sumOf { it.seriesCount },
                lastSyncAt = ms.maxOfOrNull { it.lastSyncAt } ?: 0, lastOpenedAt = l.lastOpenedAt,
                health = when { ms.isEmpty() -> LibraryEntry.Health.NEVER_READ; ms.any { it.status == SyncStatus.FAILED } -> LibraryEntry.Health.LAST_READ_FAILED; else -> LibraryEntry.Health.OK },
            )
        }
        val individual = bySource.values.map { s ->
            LibraryEntry(
                id = "src:${s.id}", name = s.name, kind = if (s.draft) LibraryEntry.Kind.UNFINISHED else LibraryEntry.Kind.CONNECTION, sourceIds = listOf(s.id),
                typeLabel = when (s.type) { SourceType.XTREAM -> "Xtream Codes"; SourceType.M3U -> "M3U URL"; SourceType.LOCAL_FILE -> "Local M3U file" },
                channelCount = s.channelCount, movieCount = s.movieCount, seriesCount = s.seriesCount, lastSyncAt = s.lastSyncAt, lastOpenedAt = s.lastOpenedAt,
                health = when {
                    s.draft -> LibraryEntry.Health.UNFINISHED
                    s.status == SyncStatus.FAILED -> LibraryEntry.Health.LAST_READ_FAILED
                    s.status == SyncStatus.NEVER -> LibraryEntry.Health.NEVER_READ
                    else -> LibraryEntry.Health.OK
                },
            )
        }
        combined + individual
    }.stateIn(scope, SharingStarted.Eagerly, emptyList())

    private val _activeId = MutableStateFlow<String?>(null)
    /** The library chosen at launch; null until one is chosen. Not remembered across launches on purpose: every launch asks. */
    val activeId: StateFlow<String?> = _activeId

    val active: StateFlow<LibraryEntry?> = combine(entries, _activeId) { all, id -> all.firstOrNull { it.id == id } }.stateIn(scope, SharingStarted.Eagerly, null)

    /** The connections every query reads. Empty until a library is open. */
    val sourceIds: StateFlow<List<String>> = active.map { it?.sourceIds.orEmpty() }.stateIn(scope, SharingStarted.Eagerly, emptyList())

    /** The id of the library opened last (for initial focus on the chooser); survives restarts. */
    val lastUsedId: String? get() = prefs.getString(LAST, null)

    suspend fun open(entry: LibraryEntry) {
        _activeId.value = entry.id
        prefs.edit().putString(LAST, entry.id).apply()
        if (entry.id.startsWith("lib:")) dao.touch(entry.id.removePrefix("lib:"), System.currentTimeMillis())
        else db.sources().touch(entry.id.removePrefix("src:"), System.currentTimeMillis())
    }

    /** Back to the chooser (Libraries in the sidebar). */
    fun close() { _activeId.value = null }

    suspend fun createCombined(name: String, sourceIds: List<String>): String {
        val id = UUID.randomUUID().toString()
        dao.put(LibraryEntity(id, name.ifBlank { "Combined library" }, System.currentTimeMillis()))
        dao.putMembers(sourceIds.map { LibraryMemberEntity(id, it) })
        return "lib:$id"
    }

    suspend fun setMembers(libraryEntryId: String, sourceIds: List<String>) {
        val id = libraryEntryId.removePrefix("lib:")
        dao.clearMembers(id); dao.putMembers(sourceIds.map { LibraryMemberEntity(id, it) })
    }

    suspend fun rename(entry: LibraryEntry, name: String) {
        if (entry.id.startsWith("lib:")) dao.get(entry.id.removePrefix("lib:"))?.let { dao.put(it.copy(name = name)) }
        else db.sources().rename(entry.id.removePrefix("src:"), name)
    }

    suspend fun deleteCombined(entry: LibraryEntry) { if (entry.id.startsWith("lib:")) { val id = entry.id.removePrefix("lib:"); dao.clearMembers(id); dao.delete(id) }; if (_activeId.value == entry.id) close() }
    suspend fun memberIds(entry: LibraryEntry): List<String> = if (entry.id.startsWith("lib:")) dao.memberIds(entry.id.removePrefix("lib:")) else listOf(entry.id.removePrefix("src:"))

    private companion object { const val LAST = "last" }
}
