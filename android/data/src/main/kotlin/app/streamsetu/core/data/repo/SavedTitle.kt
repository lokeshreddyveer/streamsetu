package app.streamsetu.core.data.repo

import app.streamsetu.core.model.ContentKind

enum class SaveState { QUEUED, DOWNLOADING, PAUSED, DONE, FAILED }

/** A movie or episode saved (or being saved) on this device to watch without a connection. The stream address is never kept: it is asked of the connection when a download starts. */
data class SavedTitle(
    val itemId: String,
    val kind: ContentKind,
    val sourceId: String,
    /** What the connection needs to find the stream ("movie:123:mp4"): not an address, and holds no login. */
    val streamRef: String,
    val seriesId: String?,
    val title: String,
    val subtitle: String?,
    val state: SaveState,
    val bytesDone: Long,
    val bytesTotal: Long,
    val fileName: String?,
    val addedAt: Long,
    val error: String?,
) {
    val fraction: Float get() = if (bytesTotal > 0) (bytesDone.toFloat() / bytesTotal).coerceIn(0f, 1f) else 0f
}

/** How the list of saved titles is kept between launches, and the rules about files and addresses, apart from the downloader so they can be tested. */
object SavedTitles {
    fun encode(list: List<SavedTitle>): String = list.joinToString("\n") { t ->
        listOf(t.itemId, t.kind.name, t.sourceId, t.streamRef, t.seriesId.orEmpty(), t.title, t.subtitle.orEmpty(), t.state.name, t.bytesDone, t.bytesTotal, t.fileName.orEmpty(), t.addedAt, t.error.orEmpty())
            .joinToString("\t") { it.toString().replace('\t', ' ').replace('\n', ' ') }
    }

    fun decode(text: String): List<SavedTitle> = text.lines().mapNotNull { line ->
        val p = line.split('\t')
        if (p.size < 13) return@mapNotNull null
        val kind = ContentKind.entries.firstOrNull { it.name == p[1] } ?: return@mapNotNull null
        val state = SaveState.entries.firstOrNull { it.name == p[7] } ?: return@mapNotNull null
        SavedTitle(p[0], kind, p[2], p[3], p[4].ifEmpty { null }, p[5], p[6].ifEmpty { null }, state, p[8].toLongOrNull() ?: 0, p[9].toLongOrNull() ?: 0, p[10].ifEmpty { null }, p[11].toLongOrNull() ?: 0, p[12].ifEmpty { null })
    }

    private val media = setOf("mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "vob", "ogv", "3gp", "ts", "mts", "m2ts")

    /** A file name that is safe on disk: the title's identity with anything but letters and digits made into "_", and the type of the stream's file (mp4 when it has none). */
    fun fileName(itemId: String, url: String): String {
        val safe = itemId.map { if (it.isLetterOrDigit()) it else '_' }.joinToString("")
        val ext = url.substringBefore('?').substringAfterLast('/', "").substringAfterLast('.', "").lowercase()
        return "$safe." + (if (ext in media) ext else "mp4")
    }

    /** A playlist such as .m3u8 is a list of pieces, not one file: it cannot be saved as a single download. */
    fun isStreamingList(url: String): Boolean = url.substringBefore('?').substringAfterLast('.', "").lowercase().let { it == "m3u8" || it == "m3u" }

    fun size(bytes: Long): String = when {
        bytes >= 1L shl 30 -> "%.1f GB".format(bytes / (1L shl 30).toDouble())
        bytes >= 1L shl 20 -> "%.0f MB".format(bytes / (1L shl 20).toDouble())
        bytes >= 1L shl 10 -> "%.0f KB".format(bytes / 1024.0)
        else -> "$bytes B"
    }
}
