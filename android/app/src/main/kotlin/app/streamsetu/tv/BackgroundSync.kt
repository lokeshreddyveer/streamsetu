package app.streamsetu.tv

import android.content.Context
import androidx.work.*
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent
import java.util.concurrent.TimeUnit

@EntryPoint
@InstallIn(SingletonComponent::class)
interface SyncEntryPoint { fun container(): AppContainer }

/**
 * Keeps catalogs fresh while the app is not in use (only when the person turned it on in Settings, only on a network, only with the battery not low).
 * It never runs while something is playing, never changes what is on screen, and a failed read keeps the last good catalog.
 */
class CatalogSyncWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val c = EntryPointAccessors.fromApplication(applicationContext, SyncEntryPoint::class.java).container()
        if (c.playback.current.value != null) return Result.success()                       // never interrupts playback
        c.sources.all().filter { !it.draft && it.enabled }.forEach { s ->
            if (c.playback.current.value != null) return Result.success()
            runCatching { c.syncWithGuide(s.id) }
        }
        runCatching { c.sync.refreshWatchedSeries(25) { c.playback.current.value != null } }
        return Result.success()
    }

    companion object {
        private const val NAME = "catalog-sync"
        /** hours = 0 turns it off. */
        fun schedule(context: Context, hours: Int) {
            val wm = WorkManager.getInstance(context)
            if (hours <= 0) { wm.cancelUniqueWork(NAME); return }
            val req = PeriodicWorkRequestBuilder<CatalogSyncWorker>(hours.toLong(), TimeUnit.HOURS)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).setRequiresBatteryNotLow(true).build()).build()
            wm.enqueueUniquePeriodicWork(NAME, ExistingPeriodicWorkPolicy.UPDATE, req)
        }
    }
}
