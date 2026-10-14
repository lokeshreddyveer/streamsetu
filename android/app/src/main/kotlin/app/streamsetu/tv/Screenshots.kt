package app.streamsetu.tv

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.os.Build
import android.provider.MediaStore
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Saves a frame of the video as a picture in Pictures/StreamSetu. */
object Screenshots {
    /** The place it was saved (for the message), or null when it could not be. */
    fun save(context: Context, bitmap: Bitmap, title: String): String? {
        val name = "StreamSetu " + SimpleDateFormat("yyyy-MM-dd HH.mm.ss", Locale.US).format(Date()) + ".png"
        return runCatching {
            if (Build.VERSION.SDK_INT >= 29) {
                val values = ContentValues().apply {
                    put(MediaStore.Images.Media.DISPLAY_NAME, name); put(MediaStore.Images.Media.MIME_TYPE, "image/png"); put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/StreamSetu"); put(MediaStore.Images.Media.TITLE, title)
                }
                val uri = context.contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values) ?: return null
                context.contentResolver.openOutputStream(uri)?.use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) } ?: return null
                "Pictures/StreamSetu"
            } else {
                val dir = File(context.getExternalFilesDir(android.os.Environment.DIRECTORY_PICTURES), "StreamSetu").also { it.mkdirs() }
                File(dir, name).outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
                dir.absolutePath.substringAfter("Android/")
            }
        }.getOrNull()
    }
}
