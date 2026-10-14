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

/**
 * A backup of favorites, positions, folders and settings, saved about once a week and only when the person left Automatic backups on. The last five are kept.
 * The backup holds no logins or stream addresses (see MaintenanceService.exportBackup).
 */
class AutoBackupWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val c = EntryPointAccessors.fromApplication(applicationContext, SyncEntryPoint::class.java).container()
        if (!c.settings.automaticBackups.value) return Result.success()
        val dir = java.io.File(applicationContext.getExternalFilesDir(null) ?: applicationContext.filesDir, "backups").also { it.mkdirs() }
        val file = java.io.File(dir, "streamsetu-auto-" + java.text.SimpleDateFormat("yyyyMMdd-HHmm", java.util.Locale.US).format(java.util.Date()) + ".json")
        runCatching { file.writeText(c.maintenance.exportBackup()) }.onFailure { file.delete(); return Result.retry() }
        dir.listFiles { f -> f.name.startsWith("streamsetu-auto-") }?.sortedByDescending { it.lastModified() }?.drop(5)?.forEach { it.delete() }
        return Result.success()
    }

    companion object {
        private const val NAME = "auto-backup"
        fun schedule(context: Context, on: Boolean) {
            val wm = WorkManager.getInstance(context)
            if (!on) { wm.cancelUniqueWork(NAME); return }
            wm.enqueueUniquePeriodicWork(NAME, ExistingPeriodicWorkPolicy.KEEP, PeriodicWorkRequestBuilder<AutoBackupWorker>(7, TimeUnit.DAYS).setConstraints(Constraints.Builder().setRequiresBatteryNotLow(true).build()).build())
        }
    }
}
