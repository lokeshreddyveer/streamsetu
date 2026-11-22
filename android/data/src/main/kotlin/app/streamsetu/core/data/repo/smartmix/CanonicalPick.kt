package app.streamsetu.core.data.repo.smartmix

import kotlin.math.abs

/**
 * One title as one card: the copies of the same film or show (other languages, other qualities, the same playlist twice) form a group, one copy is chosen to stand for it, and the others stay
 * reachable. Read-time only: no row is changed, merged or removed, and every copy keeps its id and its stream.
 */
object CanonicalPick {
    /** A copy, with what the choice and the restriction rules need. [folderId] is the provider folder it sits in. */
    data class Copy(
        val itemId: String, val kind: String, val sourceId: String, val folderId: String?, val identityKey: String, val year: Int?, val lang: String?,
        val qualityRank: Int, val addedAt: Long = 0,
    )

    /** [restricted]: some copy sits in a locked, hidden or adult-blocked folder (the whole title then stays out of recommendations). [alternatives]: the other copies the person may open. */
    data class Group(val identityKey: String, val year: Int?, val canonical: Copy, val alternatives: List<Copy>, val restricted: Boolean)

    /**
     * [preferredLang]: the language the person listens to (a name, a code is understood). [sourceRank]: lower is better (see [PreferredSource]). [accessible]: the copy's playlist is on and
     * usable. [folderRestricted]: the copy's folder is restricted for this surface. [corroborated]: two copies a year apart are the same title when this says so (otherwise only an
     * equal year matches).
     */
    class Context(
        val preferredLang: String? = null,
        val sourceRank: Map<String, Int> = emptyMap(),
        val accessible: (Copy) -> Boolean = { true },
        val folderRestricted: (Copy) -> Boolean = { false },
        val corroborated: (Copy, Copy) -> Boolean = { _, _ -> false },
    )

    /** The copy to show: preferred language, then quality, then preferred playlist, then newest added, then the id (so the same library always gives the same answer). */
    fun comparator(ctx: Context): Comparator<Copy> {
        val pref = Derive.languageName(ctx.preferredLang)
        return compareBy<Copy>({ if (pref != null && it.lang.equals(pref, true)) 0 else 1 }, { -it.qualityRank }, { ctx.sourceRank[it.sourceId] ?: Int.MAX_VALUE }, { -it.addedAt })
            .thenComparator { a, b -> a.itemId.compareTo(b.itemId) }
    }

    fun group(copies: List<Copy>, ctx: Context = Context()): List<Group> {
        val out = ArrayList<Group>()
        val byKey = LinkedHashMap<String, MutableList<Copy>>()
        for (c in copies) {
            if (c.identityKey.isEmpty()) { out += single(c, ctx); continue }
            byKey.getOrPut(c.kind + "|" + c.identityKey) { ArrayList() } += c
        }
        val order = comparator(ctx)
        for ((_, bucket) in byKey) for (cluster in cluster(bucket, ctx)) {
            val usable = cluster.filter(ctx.accessible).sortedWith(order)
            if (usable.isEmpty()) continue
            val restricted = cluster.any(ctx.folderRestricted)
            out += Group(usable.first().identityKey, usable.first().year, usable.first(), usable.drop(1).filter { !ctx.folderRestricted(it) }, restricted)
        }
        return out
    }

    private fun single(c: Copy, ctx: Context): Group = Group(c.identityKey, c.year, c, emptyList(), ctx.folderRestricted(c))

    /** Same key: equal years form a cluster; a year apart joins two clusters only when corroborated; no year joins the largest cluster when the key has two words or more. */
    private fun cluster(bucket: List<Copy>, ctx: Context): List<List<Copy>> {
        val withYear = bucket.filter { it.year != null }.groupBy { it.year!! }.toSortedMap()
        val clusters = withYear.values.map { it.toMutableList() }.toMutableList()
        // years a year apart, when something else says it is the same title
        var i = 0
        while (i < clusters.size - 1) {
            val a = clusters[i]; val b = clusters[i + 1]
            if (abs(a.first().year!! - b.first().year!!) == 1 && a.any { x -> b.any { y -> ctx.corroborated(x, y) } }) { a += b; clusters.removeAt(i + 1) } else i++
        }
        val noYear = bucket.filter { it.year == null }
        if (noYear.isNotEmpty()) {
            val multiWord = bucket.first().identityKey.contains(' ')
            if (clusters.isNotEmpty() && multiWord) clusters.maxByOrNull { it.size }!!.addAll(noYear) else clusters += noYear.toMutableList()
        }
        return clusters
    }
}

/** Which playlist's copy is preferred when copies tie on language and quality. Deterministic, no network. */
object PreferredSource {
    data class Info(val id: String, val enabled: Boolean, val draft: Boolean, val failed: Boolean, val lastSyncAt: Long, val sortOrder: Int)

    const val STALE_MS = 14L * 24 * 3600 * 1000

    /**
     * Rank by: usable (on, not a draft); healthy (not failed and read within 14 days, or the only one); the person's own choice [preferredId]; the playlist order; the id. Lower is better.
     */
    fun rank(sources: List<Info>, preferredId: String? = null, now: Long = System.currentTimeMillis()): Map<String, Int> {
        val usable = sources.filter { it.enabled && !it.draft }
        val sorted = sources.sortedWith(compareBy<Info>(
            { if (it.enabled && !it.draft) 0 else 1 },
            { if (it.failed || (usable.size > 1 && now - it.lastSyncAt > STALE_MS)) 1 else 0 },
            { if (preferredId != null && it.id == preferredId) 0 else 1 },
            { it.sortOrder }, { it.id },
        ))
        return sorted.withIndex().associate { it.value.id to it.index }
    }
}
