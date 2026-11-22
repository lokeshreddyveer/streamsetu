package app.streamsetu.core.data.smartmix

class Prepared(val inCount: Int, val groups: List<Candidate>) {
    /** folderKey -> groups whose representative is in that folder (built once, reused by every folder row). */
    val byFolder: Map<String, List<Candidate>> by lazy {
        val m = HashMap<String, ArrayList<Candidate>>()
        for (c in groups) c.folderKey?.let { m.getOrPut(it) { ArrayList() }.add(c) }
        m
    }
}

/**
 * Logical dedupe only: no row is changed. Members with the same (kind, identityKey) form clusters of release years that are at most 1 apart
 * (measured from the cluster's first year); a member without a year joins the first cluster. One representative per cluster; flags aggregate.
 */
object IdentityGrouping {
    private fun byYearThenId(a: Candidate, b: Candidate): Int {
        val ya = a.year; val yb = b.year
        if ((ya == null) != (yb == null)) return if (ya == null) 1 else -1
        if (ya != null && yb != null && ya != yb) return ya.compareTo(yb)
        return SmartMixEngine.compareUtf8(a.id, b.id)
    }

    private fun clusters(members: List<Candidate>): List<List<Candidate>> {
        val sorted = members.sortedWith(::byYearThenId)
        val starts = ArrayList<Int>(); val out = ArrayList<ArrayList<Candidate>>()
        val noYear = ArrayList<Candidate>()
        for (m in sorted) {
            val y = m.year
            if (y == null) { noYear.add(m); continue }
            if (out.isNotEmpty() && y - starts.last() <= 1) out.last().add(m) else { starts.add(y); out.add(arrayListOf(m)) }
        }
        if (noYear.isNotEmpty()) { if (out.isNotEmpty()) out[0].addAll(noYear) else out.add(noYear) }
        return out
    }

    /** Preferred language, quality, preferred source, newest added, id bytes. CAM members only count when nothing else exists. */
    private fun representative(members: List<Candidate>, prefLang: String?): Candidate {
        val pool = members.filter { !it.isCam }.ifEmpty { members }
        return pool.minWithOrNull { a, b ->
            val la = if (prefLang != null && a.lang == prefLang) 0 else 1
            val lb = if (prefLang != null && b.lang == prefLang) 0 else 1
            when {
                la != lb -> la.compareTo(lb)
                a.qualityRank != b.qualityRank -> b.qualityRank.compareTo(a.qualityRank)
                a.sourceRank != b.sourceRank -> a.sourceRank.compareTo(b.sourceRank)
                (a.addedDays == null) != (b.addedDays == null) -> if (a.addedDays == null) 1 else -1
                (a.addedDays ?: 0) != (b.addedDays ?: 0) -> (a.addedDays ?: 0).compareTo(b.addedDays ?: 0)
                else -> SmartMixEngine.compareUtf8(a.id, b.id)
            }
        }!!
    }

    fun prepare(cands: List<Candidate>, prefLang: String?): Prepared {
        val groups = HashMap<String, MutableList<Candidate>>()
        for (c in cands) groups.getOrPut(c.kind.ordinal.toString() + "|" + c.identityKey) { ArrayList(2) }.add(c)
        val reps = ArrayList<Candidate>(groups.size)
        for ((_, list) in groups) {
            for (cl in clusters(list)) {
                val rep = representative(cl, prefLang)
                var lw: Int? = null; var tr: Int? = null; var la: Int? = null
                var p7 = 0; var p30 = 0
                for (m in cl) {
                    m.lastWatchedDays?.let { lw = if (lw == null) it else minOf(lw!!, it) }
                    m.trendingRank?.let { tr = if (tr == null) it else minOf(tr!!, it) }
                    m.loadsAgo?.let { la = if (la == null) it else minOf(la!!, it) }
                    p7 += m.plays7; p30 += m.plays30
                }
                reps.add(rep.copy(
                    restricted = cl.any { it.restricted }, dismissed = cl.any { it.dismissed }, camOnly = cl.all { it.isCam },
                    watched = cl.any { it.watched }, completed = cl.any { it.completed }, lastWatchedDays = lw,
                    plays7 = p7, plays30 = p30, trendingRank = tr, loadsAgo = la,
                ))
            }
        }
        return Prepared(cands.size, reps)
    }
}
