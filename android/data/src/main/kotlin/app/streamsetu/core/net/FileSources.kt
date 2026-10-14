package app.streamsetu.core.net

import app.streamsetu.core.data.db.CategoryEntity
import app.streamsetu.core.data.db.MovieEntity
import app.streamsetu.core.model.ContentKind
import app.streamsetu.core.model.Source
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.net.URI
import javax.xml.parsers.DocumentBuilderFactory

/** One video file found on a WebDAV share or in a folder on the device. */
data class FoundVideo(val path: String, val folder: String, val name: String, val size: Long)

object VideoFiles {
    val extensions = setOf("mp4", "mkv", "avi", "mov", "m4v", "ts", "webm", "wmv", "flv", "mpg", "mpeg", "m2ts", "3gp")
    fun isVideo(name: String) = name.substringAfterLast('.', "").lowercase() in extensions

    /** "Some.Movie.2019.1080p.mkv" to "Some Movie 2019 1080p". */
    fun title(fileName: String): String = fileName.substringBeforeLast('.').replace('.', ' ').replace('_', ' ').trim().ifBlank { fileName }

    /** Rows for the catalog: each file a movie, each folder a category. [streamOf] turns a found file into the stream reference. */
    fun catalog(source: Source, found: List<FoundVideo>, streamOf: (FoundVideo) -> String): Pair<List<CategoryEntity>, List<MovieEntity>> {
        val cats = LinkedHashMap<String, CategoryEntity>()
        val movies = found.mapIndexed { i, f ->
            val folder = f.folder.ifBlank { "Files" }
            val cid = "${source.id}:${ContentKind.MOVIE.name}:$folder"
            cats.getOrPut(cid) { CategoryEntity(cid, source.id, ContentKind.MOVIE.name, folder, cats.size) }
            MovieEntity("${source.id}:mv:${f.path.hashCode()}", source.id, cid, title(f.name), null, Regex("(19|20)\\d\\d").find(f.name)?.value?.toIntOrNull(), null, null, streamOf(f), i.toLong())
        }
        return cats.values.toList() to movies
    }
}

/** WebDAV: folders and video files on a NAS or a cloud drive, read with PROPFIND and played over plain HTTP with the login in a header. */
class WebDavClient {
    fun base(source: Source): String { var a = source.address.trim(); if ("://" !in a) a = "http://$a"; return a.trimEnd('/') }

    /** What one folder holds: (href, isFolder, size). Pure, so it is tested with a canned reply. */
    fun parse(xml: String): List<Triple<String, Boolean, Long>> {
        val doc = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }.newDocumentBuilder().parse(xml.byteInputStream())
        val out = ArrayList<Triple<String, Boolean, Long>>()
        val responses = doc.getElementsByTagNameNS("*", "response")
        for (i in 0 until responses.length) {
            val r = responses.item(i) as org.w3c.dom.Element
            val href = r.getElementsByTagNameNS("*", "href").item(0)?.textContent?.trim() ?: continue
            val isDir = r.getElementsByTagNameNS("*", "collection").length > 0
            val size = r.getElementsByTagNameNS("*", "getcontentlength").item(0)?.textContent?.trim()?.toLongOrNull() ?: 0L
            out += Triple(java.net.URLDecoder.decode(href.replace("+", "%2B"), "UTF-8"), isDir, size)
        }
        return out
    }

    private fun list(source: Source, headers: Map<String, String>, url: String): List<Triple<String, Boolean, Long>> {
        val body = "<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/><d:getcontentlength/></d:prop></d:propfind>".toRequestBody("application/xml".toMediaType())
        val req = Request.Builder().url(url).method("PROPFIND", body).header("Depth", "1").apply { headers.forEach { (k, v) -> header(k, v) } }.build()
        Http.client.newCall(req).execute().use { r ->
            if (r.code == 401) error("The share refused the login. Check the user name and password.")
            if (r.code != 207 && !r.isSuccessful) error("The share answered ${r.code}. Is this a WebDAV address?")
            return parse(r.body?.string().orEmpty())
        }
    }

    /** Walks the share (up to [maxDepth] folders deep and [maxFiles] files) and returns the video files. */
    fun crawl(source: Source, headers: Map<String, String>, maxDepth: Int = 4, maxFiles: Int = 20_000): List<FoundVideo> {
        val root = URI(base(source)); val rootPath = root.path.trimEnd('/')
        val found = ArrayList<FoundVideo>()
        fun walk(path: String, depth: Int) {
            if (found.size >= maxFiles) return
            val url = "${root.scheme}://${root.rawAuthority}" + path.split('/').joinToString("/") { java.net.URLEncoder.encode(it, "UTF-8").replace("+", "%20") }.let { if (it.endsWith("/")) it else "$it/" }
            for ((href, isDir, size) in list(source, headers, url)) {
                val p = href.trimEnd('/')
                if (p == path.trimEnd('/')) continue          // the folder itself is listed first
                if (isDir) { if (depth < maxDepth) walk(p, depth + 1) }
                else if (VideoFiles.isVideo(p)) found += FoundVideo(p, p.removePrefix(rootPath).substringBeforeLast('/', "").trim('/'), p.substringAfterLast('/'), size)
            }
        }
        walk(rootPath.ifEmpty { "/" }, 0)
        return found
    }

    /** The address of a file on the share. */
    fun streamUrl(source: Source, ref: String): String {
        val root = URI(base(source)); val path = ref.removePrefix("dav:")
        return "${root.scheme}://${root.rawAuthority}" + path.split('/').joinToString("/") { java.net.URLEncoder.encode(it, "UTF-8").replace("+", "%20") }
    }
}
