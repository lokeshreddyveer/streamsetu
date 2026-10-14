package app.streamsetu.tv

import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.media.tv.TvContract
import android.os.Build
import app.streamsetu.core.model.EpisodePlayable
import app.streamsetu.core.model.MoviePlayable
import app.streamsetu.core.model.Playable

/**
 * The "Continue watching" row on the Android TV home screen. A movie or episode that was started and not finished is added with its position, and taken off again when it
 * ends; choosing it opens the app on that item. Only done on Android TV and Google TV (a Fire TV has its own home screen and ignores this, so every call is allowed to fail quietly).
 */
object WatchNext {
    private val lastWrite = HashMap<String, Long>()

    private fun available(context: Context) = Build.VERSION.SDK_INT >= 26 && context.packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK) && !context.packageManager.hasSystemFeature("amazon.hardware.fire_tv")

    /** Called with each progress save (about every ten seconds); writes at most once every 30 seconds per item, and removes the entry near the end. */
    fun update(context: Context, item: Playable, positionMs: Long, durationMs: Long) {
        if (!available(context) || item.isLive || durationMs <= 0) return
        if (positionMs >= durationMs * 0.95) { remove(context, item.id); return }
        if (positionMs < 60_000) return                       // not started yet
        val now = System.currentTimeMillis()
        if (now - (lastWrite[item.id] ?: 0L) < 30_000) return
        lastWrite[item.id] = now
        runCatching {
            val v = ContentValues().apply {
                put(TvContract.WatchNextPrograms.COLUMN_TYPE, if (item is EpisodePlayable) TvContract.WatchNextPrograms.TYPE_TV_EPISODE else TvContract.WatchNextPrograms.TYPE_MOVIE)
                put(TvContract.WatchNextPrograms.COLUMN_WATCH_NEXT_TYPE, TvContract.WatchNextPrograms.WATCH_NEXT_TYPE_CONTINUE)
                put(TvContract.WatchNextPrograms.COLUMN_LAST_ENGAGEMENT_TIME_UTC_MILLIS, now)
                put(TvContract.WatchNextPrograms.COLUMN_TITLE, if (item is EpisodePlayable) item.series.title else item.title)
                if (item is EpisodePlayable) put(TvContract.WatchNextPrograms.COLUMN_EPISODE_TITLE, item.episode.title)
                item.artworkUrl?.takeIf { it.isNotBlank() }?.let { put(TvContract.WatchNextPrograms.COLUMN_POSTER_ART_URI, it); put(TvContract.WatchNextPrograms.COLUMN_POSTER_ART_ASPECT_RATIO, TvContract.WatchNextPrograms.ASPECT_RATIO_2_3) }
                put(TvContract.WatchNextPrograms.COLUMN_LAST_PLAYBACK_POSITION_MILLIS, positionMs.toInt())
                put(TvContract.WatchNextPrograms.COLUMN_DURATION_MILLIS, durationMs.toInt())
                put(TvContract.WatchNextPrograms.COLUMN_INTERNAL_PROVIDER_ID, item.id)
                put(TvContract.WatchNextPrograms.COLUMN_INTENT_URI, "streamsetu://play?id=" + android.net.Uri.encode(item.id))
            }
            val resolver = context.contentResolver
            val existing = resolver.query(TvContract.WatchNextPrograms.CONTENT_URI, arrayOf(TvContract.WatchNextPrograms._ID), "${TvContract.WatchNextPrograms.COLUMN_INTERNAL_PROVIDER_ID}=?", arrayOf(item.id), null)?.use { if (it.moveToFirst()) it.getLong(0) else null }
            if (existing != null) resolver.update(TvContract.buildWatchNextProgramUri(existing), v, null, null) else resolver.insert(TvContract.WatchNextPrograms.CONTENT_URI, v)
        }
    }

    fun remove(context: Context, itemId: String) {
        if (!available(context)) return
        lastWrite.remove(itemId)
        runCatching { context.contentResolver.delete(TvContract.WatchNextPrograms.CONTENT_URI, "${TvContract.WatchNextPrograms.COLUMN_INTERNAL_PROVIDER_ID}=?", arrayOf(itemId)) }
    }
}
