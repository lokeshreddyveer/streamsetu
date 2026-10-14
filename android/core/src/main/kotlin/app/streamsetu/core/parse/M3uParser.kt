package app.streamsetu.core.parse

import app.streamsetu.core.model.ContentKind

/** One entry of an M3U playlist, before it is sorted into channels, movies or series. */
data class M3uEntry(
    val name: String,
    val url: String,
    val group: String?,
    val logo: String?,
    val tvgId: String?,
    val tvgName: String?,
    val channelNumber: Int?,
    val catchupDays: Int,
    val kind: ContentKind,
)

/**
 * Reads an M3U / M3U8 playlist. Works on a sequence of lines, so a playlist of hundreds of thousands of entries never sits in memory twice.
 * Tolerant by design: IPTV playlists are full of missing quotes, stray blank lines and `#EXTVLCOPT` lines.
 */
object M3uParser {
    private val attr = Regex("""([A-Za-z0-9_-]+)="([^"]*)"""")

    private val guideAttr = Regex("""(?:url-tvg|x-tvg-url)="([^"]+)"""", RegexOption.IGNORE_CASE)

    /** [onHeader] receives the guide address named in the `#EXTM3U` line, if any (the first of several). */
    fun parse(lines: Sequence<String>, onHeader: (String) -> Unit = {}, onEntry: (M3uEntry) -> Unit): Int {
        var count = 0
        var info: String? = null
        var groupOverride: String? = null
        for (raw in lines) {
            val line = raw.trim().removePrefix("﻿")
            when {
                line.isEmpty() -> {}
                line.startsWith("#EXTM3U", ignoreCase = true) -> guideAttr.find(line)?.groupValues?.get(1)?.split(',', ' ')?.firstOrNull { it.isNotBlank() }?.let(onHeader)
                line.startsWith("#EXTINF", ignoreCase = true) -> info = line      // an #EXTGRP seen just before keeps applying
                line.startsWith("#EXTGRP:", ignoreCase = true) -> groupOverride = line.substringAfter(':').trim()
                line.startsWith("#") -> {}
                info != null -> {
                    onEntry(entry(info, line, groupOverride))
                    count++
                    info = null; groupOverride = null
                }
            }
        }
        return count
    }

    fun parse(text: String): List<M3uEntry> {
        val out = ArrayList<M3uEntry>()
        parse(text.lineSequence()) { out += it }
        return out
    }

    internal fun entry(info: String, url: String, groupOverride: String?): M3uEntry {
        val attrs = attr.findAll(info).associate { it.groupValues[1].lowercase() to it.groupValues[2] }
        // The title is whatever follows the last comma that is outside quotes.
        val title = lastCommaTitle(info)
        val name = title.ifBlank { attrs["tvg-name"].orEmpty() }.ifBlank { url.substringAfterLast('/') }
        val group = (attrs["group-title"] ?: groupOverride)?.trim()?.takeIf { it.isNotEmpty() }
        return M3uEntry(
            name = name.trim(),
            url = url,
            group = group,
            logo = attrs["tvg-logo"]?.takeIf { it.isNotBlank() },
            tvgId = attrs["tvg-id"]?.takeIf { it.isNotBlank() },
            tvgName = attrs["tvg-name"]?.takeIf { it.isNotBlank() },
            channelNumber = (attrs["tvg-chno"] ?: attrs["channel-number"])?.toIntOrNull(),
            catchupDays = attrs["catchup-days"]?.toIntOrNull() ?: 0,
            kind = classify(url, group),
        )
    }

    private fun lastCommaTitle(info: String): String {
        var inQuotes = false
        var last = -1
        for ((i, c) in info.withIndex()) {
            if (c == '"') inQuotes = !inQuotes
            if (c == ',' && !inQuotes) last = i
        }
        return if (last >= 0) info.substring(last + 1) else ""
    }

    /** Providers mark movies and series in the address path (`/movie/`, `/series/`), and many also in the group name. */
    internal fun classify(url: String, group: String?): ContentKind {
        val path = url.substringAfter("://", url).substringAfter('/', "").lowercase()
        return when {
            path.startsWith("movie/") || "/movie/" in path -> ContentKind.MOVIE
            path.startsWith("series/") || "/series/" in path -> ContentKind.EPISODE
            group?.lowercase()?.let { it.startsWith("vod") || it.startsWith("movies") || it.startsWith("film") } == true &&
                !url.contains(".m3u8") && !url.endsWith(".ts") -> ContentKind.MOVIE
            else -> ContentKind.CHANNEL
        }
    }
}
