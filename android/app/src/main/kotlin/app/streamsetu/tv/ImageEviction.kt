package app.streamsetu.tv

import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.repo.FolderRepository
import app.streamsetu.core.data.repo.RestrictedPictures
import app.streamsetu.core.data.repo.Visibility
import app.streamsetu.core.model.ContentKind
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * Pictures of a folder that has just become restricted (locked, hidden, adult-blocked) are taken out of Coil's memory and disk caches, in the background and in chunks, so the artwork of a
 * locked folder does not outlive the lock. It also runs once at start, which covers a lock made just before the app was stopped. The cache keys are the picture addresses (no custom
 * key is set by [app.streamsetu.tv.ui.components.artworkRequest]); memory entries add the size to the key, so they are matched by address.
 */
object ImageEviction {
    fun evict(loader: coil.ImageLoader, urls: Collection<String>) {
        if (urls.isEmpty()) return
        val set = urls.toHashSet()
        loader.memoryCache?.let { mem -> mem.keys.filter { it.key in set }.forEach { mem.remove(it) } }
        loader.diskCache?.let { disk -> for (u in urls) runCatching { disk.remove(u) } }
    }

    fun watch(scope: CoroutineScope, db: AppDatabase, folders: FolderRepository, onRestricted: suspend (Set<String>) -> Unit = {}, loader: () -> coil.ImageLoader) {
        scope.launch(Dispatchers.IO) {
            var seen = emptySet<String>()
            var unlockedBefore = emptySet<String>()
            folders.restrictRev.collect {
                val now = HashSet<String>()
                for (k in listOf(ContentKind.MOVIE, ContentKind.SERIES, ContentKind.CHANNEL)) now += folders.visibility.excludedFolders(k, Visibility.Surface.RECOMMEND)
                // A folder unlocked with the PIN and locked again is not "new" (the strictest rule never counted it as open), but what was browsed meanwhile is in the caches: every relock evicts it all again.
                val unlockedNow = folders.unlockedFolders
                val relocked = (unlockedBefore - unlockedNow).isNotEmpty(); unlockedBefore = unlockedNow
                val added = if (relocked) now else now - seen
                seen = now
                if (added.isNotEmpty()) { runCatching { evict(loader(), RestrictedPictures.urlsIn(db, added)) }; onRestricted(added) }          // also what TMDB filled in and what was kept about them
            }
        }
    }
}
