package app.streamsetu.core.data.repo

import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Recordings of live channels: files kept on this device, named by what was recorded and when. */
object RecordingFiles {
    data class Item(val file: File, val title: String, val startedAt: Long, val bytes: Long)

    private fun stamp() = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US)

    /** "News 24__20261017-211500.ts": the channel's name (made safe for a file), two underscores, and when it started. */
    fun fileName(channel: String, startedAt: Long): String {
        val safe = channel.map { if (it.isLetterOrDigit() || it == ' ' || it == '-') it else '_' }.joinToString("").trim().ifEmpty { "Channel" }
        return safe + "__" + stamp().format(Date(startedAt)) + ".ts"
    }

    fun parse(fileName: String): Pair<String, Long>? {
        val base = fileName.substringBeforeLast('.')
        val cut = base.lastIndexOf("__")
        if (cut < 0) return null
        val date = runCatching { stamp().parse(base.substring(cut + 2)) }.getOrNull() ?: return null
        return base.substring(0, cut) to date.time
    }

    /** Everything recorded in [folder], newest first. */
    fun list(folder: File): List<Item> = folder.listFiles().orEmpty().filter { it.extension == "ts" }.mapNotNull { f ->
        parse(f.name)?.let { (title, at) -> Item(f, title, at, f.length()) }
    }.sortedByDescending { it.startedAt }

    /** The id a recording plays under, and back. */
    fun playId(fileName: String) = "recording:$fileName"
    fun fileOf(playId: String): String? = playId.removePrefix("recording:").takeIf { playId.startsWith("recording:") }
}
