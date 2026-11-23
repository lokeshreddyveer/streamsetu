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

/**
 * Keeps what TMDB gave this device fresh and within its limits: nothing is fetched without a credential (the person's own key, else the built-in token) and the weekly-list switch; the weekly list is
 * refreshed once it is a week old; anything saved is deleted after 180 days. Never runs while something plays.
 */
class TmdbRefreshWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val c = EntryPointAccessors.fromApplication(applicationContext, SyncEntryPoint::class.java).container()
        // The 180-day limit and the folder rules apply whether or not there is a key any more.
        runCatching { c.tmdbService.purge() }
        if (!c.tmdbAuth.available) return Result.success()          // no key of the person's and no usable built-in token: nothing is asked
        app.streamsetu.core.data.repo.TmdbFiles.purge(c.tmdbDir)
        runCatching { c.tmdbService.purge() }          // what TMDB filled in: gone after 180 days, and for anything restricted since
        if (c.playback.current.value != null) return Result.success()
        // Asks the provider for the view: it refreshes when the list is a week old, clears the saved list when the switch is off, and stays quiet after a failure for an hour.
        runCatching { kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { c.trendingSource.view(System.currentTimeMillis()) } }
        return Result.success()
    }
    companion object {
        private const val NAME = "tmdb-refresh"
        fun schedule(context: Context) {
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(NAME, ExistingPeriodicWorkPolicy.KEEP,
                PeriodicWorkRequestBuilder<TmdbRefreshWorker>(12, TimeUnit.HOURS).setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).setRequiresBatteryNotLow(true).build()).build())
        }
    }
}

/** When the automatic artwork run may go: on any connected network (mobile data too, unless the person switched it off), with the battery not low. Android's Data Saver is not looked at. */
object ArtworkPolicy {
    /** The rule alone, so it can be tested. */
    fun decide(connected: Boolean, metered: Boolean, mobileDataOk: Boolean, batteryLow: Boolean): Boolean =
        connected && !batteryLow && (!metered || mobileDataOk)

    fun online(context: Context): Boolean = runCatching {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as android.net.ConnectivityManager
        activeCaps(cm)
    }.getOrDefault(true)
    /** Whether the active network reaches the internet; below Android 6 (no active-network call) the older connection info answers. */
    @Suppress("DEPRECATION")
    private fun activeCaps(cm: android.net.ConnectivityManager): Boolean =
        if (android.os.Build.VERSION.SDK_INT >= 23) cm.activeNetwork?.let { cm.getNetworkCapabilities(it) }?.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
        else cm.activeNetworkInfo?.isConnected == true
    /** Why the bulk run is paused right now (only the bulk run: what the person looks at is never held back). */
    fun cause(context: Context, mobileDataOk: Boolean): app.streamsetu.core.data.repo.ArtworkMatchEngine.PauseCause {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as android.net.ConnectivityManager
        return when {
            !online(context) -> app.streamsetu.core.data.repo.ArtworkMatchEngine.PauseCause.OFFLINE
            runCatching { cm.isActiveNetworkMetered }.getOrDefault(false) && !mobileDataOk -> app.streamsetu.core.data.repo.ArtworkMatchEngine.PauseCause.METERED
            else -> app.streamsetu.core.data.repo.ArtworkMatchEngine.PauseCause.BATTERY
        }
    }

    fun allowed(context: Context, mobileDataOk: Boolean): Boolean = runCatching {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as android.net.ConnectivityManager
        val connected = activeCaps(cm)
        val b = context.registerReceiver(null, android.content.IntentFilter(android.content.Intent.ACTION_BATTERY_CHANGED))
        val low = b != null && (b.getIntExtra(android.os.BatteryManager.EXTRA_LEVEL, 100) * 100 / b.getIntExtra(android.os.BatteryManager.EXTRA_SCALE, 100).coerceAtLeast(1)) < 15 && b.getIntExtra(android.os.BatteryManager.EXTRA_PLUGGED, 0) == 0
        decide(connected, cm.isActiveNetworkMetered, mobileDataOk, low)
    }.getOrDefault(true)
}

/**
 * Carries on matching artwork when the app is not open: the same run as in the app ([app.streamsetu.core.data.repo.ArtworkMatchEngine], resumed from its saved cursor), in slices of a few minutes.
 * A slice that ends before the queue does hands over to the next one; a back-off waits for its time. It stops by itself when the switch is off or there is no credential.
 */
class TmdbMatchWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val c = EntryPointAccessors.fromApplication(applicationContext, SyncEntryPoint::class.java).container()
        if (!c.ui.artworkMatching.value || !c.tmdbAuth.available) return Result.success()
        runCatching { c.tmdbService.purge() }
        when (val r = c.artworkEngine.runOnce(System.currentTimeMillis() + SLICE_MS)) {
            is app.streamsetu.core.data.repo.ArtworkMatchEngine.Result.TimeUp -> continueAfter(applicationContext, 0, c.ui.artworkMatchingCellular.value)
            is app.streamsetu.core.data.repo.ArtworkMatchEngine.Result.Backoff -> continueAfter(applicationContext, (r.until - System.currentTimeMillis()).coerceAtLeast(60_000), c.ui.artworkMatchingCellular.value)
            else -> {}
        }
        return Result.success()
    }
    companion object {
        private const val NAME = "artwork-match"; private const val CONTINUE = "artwork-match-next"
        private const val SLICE_MS = 8 * 60_000L
        private fun constraints(cellular: Boolean) = Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).setRequiresBatteryNotLow(true).build()
        private fun continueAfter(context: Context, delayMs: Long, cellular: Boolean) {
            WorkManager.getInstance(context).enqueueUniqueWork(CONTINUE, ExistingWorkPolicy.REPLACE, OneTimeWorkRequestBuilder<TmdbMatchWorker>().setInitialDelay(delayMs, TimeUnit.MILLISECONDS).setConstraints(constraints(cellular)).build())
        }
        /** Re-asserts the schedule: a periodic run every 6 hours plus one at once; off removes both. */
        fun schedule(context: Context, on: Boolean, cellular: Boolean) {
            val wm = WorkManager.getInstance(context)
            if (!on) { wm.cancelUniqueWork(NAME); wm.cancelUniqueWork(CONTINUE); return }
            wm.enqueueUniquePeriodicWork(NAME, ExistingPeriodicWorkPolicy.UPDATE, PeriodicWorkRequestBuilder<TmdbMatchWorker>(6, TimeUnit.HOURS).setConstraints(constraints(cellular)).build())
            continueAfter(context, 0, cellular)
        }
    }
}

/**
 * Keeps the guides the person added fresh, and the public channel database when that is on (about every six hours, on a network, battery not low). It never runs while something is
 * playing, and a failed read keeps the guide that was there.
 */
class GuideHubWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val c = EntryPointAccessors.fromApplication(applicationContext, SyncEntryPoint::class.java).container()
        if (c.playback.current.value != null) return Result.success()
        return if (runCatching { c.guideHub.refresh(force = false) }.isSuccess) Result.success() else Result.retry()
    }

    companion object {
        private const val NAME = "guide-hub"
        fun schedule(context: Context) {
            val req = PeriodicWorkRequestBuilder<GuideHubWorker>(6, TimeUnit.HOURS)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).setRequiresBatteryNotLow(true).build()).build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(NAME, ExistingPeriodicWorkPolicy.KEEP, req)
        }
    }
}
