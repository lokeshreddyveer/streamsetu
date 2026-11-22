package app.streamsetu.core.data.db

import android.content.Context
import kotlinx.coroutines.CompletableDeferred

/**
 * Creates a database once and opens it (and, after an update, migrates it: Room 10 to 11 builds two indexes) on a background thread, so the first screen does not wait on it on the main
 * thread. [instance] gives the same object to every caller; [ready] completes when the first open has finished (also on failure, so nobody waits for ever).
 */
class DatabaseOpener<T : androidx.room.RoomDatabase>(private val create: () -> T) {
    private var db: T? = null
    val ready = CompletableDeferred<Unit>()
    @Volatile var openedAtMs: Long = -1; private set

    @Synchronized fun instance(): T = db ?: create().also { db = it }

    /** Closes the database, if one was created. Used only when a new application object replaces this one (a test starts a new app for every test). */
    @Synchronized fun close() { runCatching { db?.close() }; db = null }

    /** Starts the first open on its own thread; returns at once. */
    fun start() {
        if (openedAtMs != -1L) return
        openedAtMs = -3
        Thread({
            val t = System.nanoTime()
            try { instance().openHelper.writableDatabase; openedAtMs = (System.nanoTime() - t) / 1_000_000 } catch (e: Throwable) { openedAtMs = -2 }
            ready.complete(Unit)
        }, "db-warmup").apply { isDaemon = true }.start()
    }
}

/** The app's own database, opened early by the Application and handed to the wiring. */
object DatabaseWarmup {
    private var opener: DatabaseOpener<AppDatabase>? = null
    private var owner: java.lang.ref.WeakReference<Context>? = null

    /**
     * One opener per application object. A phone has exactly one, so this is one database for the life of the process; the only time the application
     * object changes is in tests, where each test builds its own app, and then the old opener is closed and a fresh one starts, so no test inherits a
     * database (or its threads) from another.
     */
    @Synchronized private fun of(context: Context, logQueries: Boolean, queryThreads: Int): DatabaseOpener<AppDatabase> {
        val app = context.applicationContext
        val current = opener
        if (current != null && owner?.get() === app) return current
        current?.close()
        return DatabaseOpener { AppDatabase.open(app, logQueries, queryThreads) }.also { opener = it; owner = java.lang.ref.WeakReference(app) }
    }

    fun instance(context: Context, logQueries: Boolean = false, queryThreads: Int = 4): AppDatabase = of(context, logQueries, queryThreads).instance()
    fun start(context: Context, logQueries: Boolean = false, queryThreads: Int = 4) = of(context, logQueries, queryThreads).start()
}
