package app.streamsetu.core.data.repo

import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.db.CategoryEntity
import app.streamsetu.core.data.repo.smartmix.IdentityKey
import app.streamsetu.core.model.*

/**
 * Who may see which folder, in one place. Three surfaces ask differently:
 *  - [Surface.HISTORY]: what the person already watched (Continue Watching, Recently Watched). Folders that are locked (and not unlocked with the PIN) and adult folders (while adult content
 *    is hidden, always for a kids profile) are left out of what is drawn. Nothing is deleted or changed: the entries come back the moment the folder is unlocked.
 *  - [Surface.SEARCH]: the same, plus folders the person hid. Used by search, suggestions, similar titles, versions, shared links.
 *  - [Surface.RECOMMEND]: banners, shelves and "For You" seeds' results. The strictest: locked folders stay out even after an unlock (what is built then is cached and shown later),
 *    same-named folders of other playlists are covered, and a title is out when ANY copy of it (another language, another playlist) sits in a restricted folder.
 * Nothing is read from the catalog tables except folder names and, for the title rule, the titles of restricted folders.
 */
class Visibility(
    private val db: AppDatabase,
    private val hideAdult: () -> Boolean,
    /** The folders unlocked with the PIN right now (after the auto-relock has been applied). */
    private val unlockedNow: () -> Set<String>,
) {
    enum class Surface { HISTORY, SEARCH, RECOMMEND }

    /** Folder ids to leave out, for one kind. */
    suspend fun excludedFolders(kind: ContentKind, surface: Surface): Set<String> {
        val prefs = db.folders().all().filter { it.scope == kind.name }
        val cats = db.catalog().categoriesOfKind(kind.name)
        return excluded(cats, prefs.filter { it.locked }.map { it.folderId }.toSet(), prefs.filter { it.hidden }.map { it.folderId }.toSet(), surface)
    }

    private fun excluded(cats: List<CategoryEntity>, locked: Set<String>, hidden: Set<String>, surface: Surface): Set<String> {
        val lockedNow = if (surface == Surface.RECOMMEND) locked else locked - unlockedNow()
        val adult = if (hideAdult()) cats.filter { ParentalControls.isAdultName(it.name) }.map { it.id }.toSet() else emptySet()
        val hiddenNow = if (surface == Surface.HISTORY) emptySet() else hidden
        var out = lockedNow + adult + hiddenNow
        if (surface == Surface.RECOMMEND) {
            // A folder with the same name in another playlist is the same folder to the person (twin playlists, a playlist added later): covered whether or not it was marked by hand.
            val names = cats.filter { it.id in out }.map { FolderNames.family(it.name) }.toSet()
            out = out + cats.filter { FolderNames.family(it.name) in names }.map { it.id }
        }
        return out
    }

    /** A frozen view for one computation: ask it about many items without more reads. */
    suspend fun snapshot(surface: Surface): Snapshot {
        val prefs = db.folders().all()
        val out = HashMap<ContentKind, Set<String>>(); val twins = HashMap<ContentKind, TwinIndex>()
        for (kind in ContentKind.values()) {
            if (kind != ContentKind.MOVIE && kind != ContentKind.SERIES && kind != ContentKind.CHANNEL) continue
            val cats = db.catalog().categoriesOfKind(kind.name)
            val p = prefs.filter { it.scope == kind.name }
            val ex = excluded(cats, p.filter { it.locked }.map { it.folderId }.toSet(), p.filter { it.hidden }.map { it.folderId }.toSet(), surface)
            out[kind] = ex
            if (surface == Surface.RECOMMEND && ex.isNotEmpty() && (kind == ContentKind.MOVIE || kind == ContentKind.SERIES)) twins[kind] = twinIndex(kind, ex)
        }
        return Snapshot(out, twins)
    }

    private data class TwinCache(val kind: ContentKind, val folders: Set<String>, val revision: String, val index: TwinIndex)
    @Volatile private var twinCache: Map<ContentKind, TwinCache> = emptyMap()

    private suspend fun twinIndex(kind: ContentKind, folders: Set<String>): TwinIndex {
        val revision = db.catalog().fingerprintRevisionNow()
        twinCache[kind]?.takeIf { it.folders == folders && it.revision == revision }?.let { return it.index }
        val index = TwinIndex()
        for (chunk in folders.toList().chunked(400)) {
            val rows = if (kind == ContentKind.MOVIE) db.catalog().movieTitlesIn(chunk) else db.catalog().seriesTitlesIn(chunk)
            for (r in rows) index.add(r.title, r.year)
        }
        synchronized(this) { twinCache = twinCache + (kind to TwinCache(kind, folders, revision, index)) }
        return index
    }

    /** Keys (and years) of the titles that sit in a restricted folder. */
    class TwinIndex {
        private val byKey = HashMap<String, MutableList<Int?>>()
        fun add(title: String, year: Int?) { byKey.getOrPut(IdentityKey.ofOrFallback(title)) { ArrayList(1) } += IdentityKey.yearOf(title, year) }
        val size get() = byKey.size
        /** True when this title is a copy of one in a restricted folder. A year apart counts as the same: when in doubt the title is held back. */
        fun covers(title: String, year: Int?): Boolean {
            val key = IdentityKey.ofOrFallback(title)
            val years = byKey[key] ?: return false
            val y = IdentityKey.yearOf(title, year)
            return years.any { o -> if (y == null || o == null) (y == null && o == null) || key.contains(' ') else kotlin.math.abs(y - o) <= 1 }
        }
    }

    class Snapshot internal constructor(private val excluded: Map<ContentKind, Set<String>>, private val twins: Map<ContentKind, TwinIndex>) {
        fun folderOk(kind: ContentKind, folderId: String?) = folderId == null || folderId !in (excluded[kind] ?: emptySet())
        fun excluded(kind: ContentKind): Set<String> = excluded[kind] ?: emptySet()
        fun movieOk(m: Movie) = folderOk(ContentKind.MOVIE, m.categoryId) && twins[ContentKind.MOVIE]?.covers(m.title, m.year) != true
        fun seriesOk(s: Series) = folderOk(ContentKind.SERIES, s.categoryId) && twins[ContentKind.SERIES]?.covers(s.title, s.year) != true
        fun channelOk(c: Channel) = folderOk(ContentKind.CHANNEL, c.categoryId)
        /** The same rule for a row that carries only what the rule reads (a candidate pool row). */
        fun titleOk(kind: ContentKind, folderId: String?, title: String, year: Int?) = folderOk(kind, folderId) && twins[kind]?.covers(title, year) != true
    }

}

/** Folder names compared across playlists. */
object FolderNames {
    /** "ENGLISH | GENERAL" and "English | General" are one folder family. */
    fun family(name: String): String = IdentityKey.normalize(name)
}

/** Which pictures to drop from the picture caches when folders become restricted: the addresses of everything in them. */
object RestrictedPictures {
    suspend fun urlsIn(db: AppDatabase, folderIds: Set<String>): Set<String> {
        val out = HashSet<String>()
        for (chunk in folderIds.toList().chunked(400)) {
            out += db.catalog().moviePicturesIn(chunk); out += db.catalog().seriesPicturesIn(chunk); out += db.catalog().channelPicturesIn(chunk); out += db.catalog().episodePicturesIn(chunk)
        }
        out.removeAll { it.isBlank() }
        return out
    }
}
