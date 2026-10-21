package app.streamsetu.tv

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.core.content.ContextCompat

/** A video or a picture stored on this device. */
data class DeviceItem(val uri: String, val name: String, val durationMs: Long, val video: Boolean, val addedSec: Long, val sizeBytes: Long)

/**
 * The videos and pictures on this device, read from Android's media store. Nothing is copied or sent: a video plays from where it is, a picture is shown from where it is.
 * Asking needs the permission to read media, which Android asks for once.
 */
object DeviceMedia {
    private const val PREFIX = "device:"

    fun permissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= 33) arrayOf(Manifest.permission.READ_MEDIA_VIDEO, Manifest.permission.READ_MEDIA_IMAGES) else arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)

    fun granted(context: Context) = permissions().all { ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED }

    /** The id a video is played under; the player finds the file again from it. */
    fun playId(uri: String) = PREFIX + Uri.encode(uri)
    fun uriOf(id: String): String? = if (id.startsWith(PREFIX)) Uri.decode(id.removePrefix(PREFIX)) else null

    /** Newest first. */
    fun videos(context: Context, limit: Int = 500): List<DeviceItem> = query(context, MediaStore.Video.Media.EXTERNAL_CONTENT_URI, true, limit)
    fun pictures(context: Context, limit: Int = 500): List<DeviceItem> = query(context, MediaStore.Images.Media.EXTERNAL_CONTENT_URI, false, limit)

    private fun query(context: Context, collection: Uri, video: Boolean, limit: Int): List<DeviceItem> {
        val cols = if (video) arrayOf(MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.Video.VideoColumns.DURATION, MediaStore.MediaColumns.DATE_ADDED, MediaStore.MediaColumns.SIZE)
        else arrayOf(MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.MediaColumns.DATE_ADDED, MediaStore.MediaColumns.SIZE)
        val out = ArrayList<DeviceItem>()
        runCatching {
            context.contentResolver.query(collection, cols, null, null, "${MediaStore.MediaColumns.DATE_ADDED} DESC")?.use { c ->
                while (c.moveToNext() && out.size < limit) {
                    val id = c.getLong(0)
                    val uri = ContentUris.withAppendedId(collection, id).toString()
                    out += if (video) DeviceItem(uri, c.getString(1).orEmpty(), c.getLong(2), true, c.getLong(3), c.getLong(4))
                    else DeviceItem(uri, c.getString(1).orEmpty(), 0, false, c.getLong(2), c.getLong(3))
                }
            }
        }
        return out
    }

    fun clock(ms: Long): String {
        val s = (ms / 1000).toInt()
        return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s / 60 % 60, s % 60) else "%d:%02d".format(s / 60, s % 60)
    }
}
