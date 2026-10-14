package app.streamsetu.tv

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import app.streamsetu.core.net.FoundVideo
import app.streamsetu.core.net.VideoFiles

/** Lists the video files in a folder the person chose (through the system folder picker), including sub-folders four levels deep. */
object LocalFolder {
    fun list(context: Context, treeUri: String, maxDepth: Int = 4, maxFiles: Int = 20_000): List<FoundVideo> {
        val tree = Uri.parse(treeUri)
        val found = ArrayList<FoundVideo>()
        fun walk(docId: String, folder: String, depth: Int) {
            if (found.size >= maxFiles) return
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, docId)
            val rows = ArrayList<Array<String?>>()
            context.contentResolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.COLUMN_SIZE), null, null, null)?.use { c ->
                while (c.moveToNext()) rows += arrayOf(c.getString(0), c.getString(1), c.getString(2), if (c.isNull(3)) "0" else c.getString(3))
            }
            for ((id, name, mime, size) in rows.map { listOf(it[0], it[1], it[2], it[3]) }) {
                if (id == null || name == null) continue
                if (mime == DocumentsContract.Document.MIME_TYPE_DIR) { if (depth < maxDepth) walk(id, if (folder.isEmpty()) name else "$folder/$name", depth + 1) }
                else if (VideoFiles.isVideo(name)) found += FoundVideo(DocumentsContract.buildDocumentUriUsingTree(tree, id).toString(), folder, name, size?.toLongOrNull() ?: 0)
            }
        }
        walk(DocumentsContract.getTreeDocumentId(tree), "", 0)
        return found
    }
}
