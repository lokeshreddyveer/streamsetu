package app.streamsetu.core.data.guidehub

data class GuideMatch(val guideSourceId: String, val xmltvId: String, val method: String, val confidence: Double, val reason: String)
data class MapChannel(
    val id: String, val name: String, val tvgId: String? = null, val providerId: String? = null, val country: String? = null, val language: String? = null,
    val ownGuideSource: String? = null, val altNames: List<String> = emptyList(), val restricted: Boolean = false, val userLock: GuideMatch? = null,
)
data class MapGuideChannel(val sourceId: String, val xmltvId: String, val names: List<String>, val country: String? = null, val language: String? = null, val priority: Int = 10)
data class MappingResult(val channelId: String, val match: GuideMatch?, val suggestions: List<GuideMatch>, val unmapped: String?)
data class MappingOptions(val autoThreshold: Double = 0.60, val suggestionFloor: Double = 0.40, val fuzzyMinRatio: Double = 0.88, val fuzzyMargin: Double = 0.05, val maxFuzzyComparisons: Int = 2000)

/** Channel-to-guide mapping: user lock, exact id (own 0.99, other 0.95), normalised id 0.90, provider id 0.85, alias 0.80, equal name 0.70 (+tie-breaks), fuzzy 0.40-0.65. Auto from 0.60. A port of the Apple `GuideMappingEngine`. */
object GuideMappingEngine {
    private class Entry(val g: MapGuideChannel, val cc: String?, val lang: String?, val keys: List<ChannelNormalizer.NameKey>)
    private class Flat(val entry: Int, val variant: String, val size: Int)

    fun map(channels: List<MapChannel>, guide: List<MapGuideChannel>, o: MappingOptions = MappingOptions()): List<MappingResult> {
        val entries = ArrayList<Entry>(guide.size)
        val byExact = HashMap<String, MutableList<Int>>()
        val byIdBase = HashMap<String, MutableList<Int>>()
        val byName = HashMap<String, MutableList<Int>>()
        val postings = HashMap<String, MutableList<Int>>()
        val flat = ArrayList<Flat>()
        for ((i, g) in guide.withIndex()) {
            val idCc = ChannelNormalizer.idParts(g.xmltvId).second
            val keys = (g.names + listOf(if (g.xmltvId.contains(".")) "" else g.xmltvId)).map(ChannelNormalizer::name).filter { !it.isEmpty }
            entries.add(Entry(g, ChannelNormalizer.countryKey(g.country) ?: ChannelNormalizer.countryKey(idCc), ChannelNormalizer.languageKey(g.language), keys))
            byExact.getOrPut(g.sourceId + "\u0001" + g.xmltvId) { mutableListOf() }.add(i)
            byExact.getOrPut("\u0002" + g.xmltvId) { mutableListOf() }.add(i)
            byIdBase.getOrPut(ChannelNormalizer.idParts(g.xmltvId).first) { mutableListOf() }.add(i)
            val seen = HashSet<String>()
            for (k in keys) {
                if (seen.add(k.key)) byName.getOrPut(k.key) { mutableListOf() }.add(i)
                val uniq = k.tokens.toSet()
                val id = flat.size
                flat.add(Flat(i, k.variant, uniq.size))
                for (t in uniq) postings.getOrPut(t) { mutableListOf() }.add(id)
            }
        }
        val commonCutoff = maxOf(50, guide.size / 10)
        fun better(a: Int, b: Int): Boolean { val pa = entries[a].g.priority; val pb = entries[b].g.priority; return if (pa != pb) pa < pb else a < b }
        fun pickByPriority(idx: List<Int>): Int? = idx.reduceOrNull { a, b -> if (better(b, a)) b else a }

        fun mapOne(ch: MapChannel, trustIDs: Boolean): MappingResult {
            ch.userLock?.let { return MappingResult(ch.id, it, emptyList(), null) }
            if (ch.restricted) return MappingResult(ch.id, null, emptyList(), "restricted")
            val chCc = ChannelNormalizer.countryKey(ch.country)
            val chLang = ChannelNormalizer.languageKey(ch.language)
            val nameKey = ChannelNormalizer.name(ch.name)
            val ownCc = chCc ?: nameKey.countryPrefix?.let(ChannelNormalizer::countryKey)

            fun result(i: Int, method: String, conf: Double, reason: String): MappingResult {
                val m = GuideMatch(entries[i].g.sourceId, entries[i].g.xmltvId, method, conf, reason)
                val auto = conf >= o.autoThreshold
                return MappingResult(ch.id, if (auto) m else null, if (auto) emptyList() else listOf(m), if (auto) null else "belowThreshold")
            }
            fun narrow(idx: List<Int>): Pair<Int, Double>? {
                if (idx.isEmpty()) return null
                if (idx.size == 1) return idx[0] to 0.0
                var pool = idx
                var bonus = 0.0
                if (ownCc != null) {
                    val same = pool.filter { entries[it].cc == ownCc }
                    if (same.isNotEmpty() && same.size < pool.size) { pool = same; bonus += 0.10 } else if (same.isNotEmpty()) bonus += 0.10
                }
                if (pool.size > 1 && chLang != null) {
                    val same = pool.filter { entries[it].lang == chLang }
                    if (same.isNotEmpty() && same.size < pool.size) { pool = same; bonus += 0.05 }
                }
                if (pool.size == 1) return pool[0] to bonus
                val best = pool.minOf { entries[it].g.priority }
                val top = pool.filter { entries[it].g.priority == best }
                if (top.map { entries[it].g.xmltvId }.toSet().size == 1) pickByPriority(top)?.let { return it to bonus }
                return null
            }

            /** An id found only in another source (the own playlist's guide is trusted) that names a channel with nothing in common with this channel's name is a wrong id: the name is tried first. */
            fun guarded(i: Int, r: MappingResult): MappingResult {
                if (!trustIDs || r.match == null || nameKey.isEmpty) return r
                fun split(t: List<String>): Pair<Set<String>, Set<String>> = t.filter { w -> w.any { !it.isDigit() } }.toSet() to t.filter { w -> w.all { it.isDigit() } }.toSet()
                val a = split(nameKey.tokens)
                if (entries[i].keys.any { val b = split(it.tokens); a.first.intersect(b.first).isNotEmpty() && a.second == b.second }) return r
                val alt = mapOne(ch.copy(tvgId = null, providerId = null), false)
                val am = alt.match
                if (am != null && (am.method == "name" || am.method == "alias")) return alt
                return r
            }
            val tvg = if (trustIDs) ch.tvgId?.trim() else null
            if (!tvg.isNullOrEmpty()) {
                ch.ownGuideSource?.let { own -> byExact[own + "\u0001" + tvg]?.let { hit -> pickByPriority(hit)?.let { return result(it, "exact", 0.99, "id in own guide") } } }
                byExact["\u0002" + tvg]?.let { hit -> pickByPriority(hit)?.let { return guarded(it, result(it, "exactOther", 0.95, "id in another guide")) } }
                val b = ChannelNormalizer.idParts(tvg).first
                byIdBase[b]?.let { hit ->
                    val ok = hit.filter { ChannelNormalizer.idsEqualNormalised(tvg, entries[it].g.xmltvId) }
                    narrow(ok)?.let { return guarded(it.first, result(it.first, "normalisedID", 0.90, "id after normalising")) }
                }
            }
            val pid = ch.providerId
            if (trustIDs && !pid.isNullOrEmpty() && ch.ownGuideSource != null) {
                byExact[ch.ownGuideSource + "\u0001" + pid]?.let { hit -> pickByPriority(hit)?.let { return result(it, "provider", 0.85, "provider id is the guide id") } }
            }
            if (nameKey.isEmpty) return MappingResult(ch.id, null, emptyList(), "noCandidate")

            if (ch.altNames.isNotEmpty()) {
                val hits = ArrayList<Int>()
                for (alt in ch.altNames) {
                    val k = ChannelNormalizer.name(alt)
                    if (k.isEmpty || k.variant != nameKey.variant) continue
                    byName[k.key]?.let { hits.addAll(it) }
                }
                val uniq = hits.toSet().sorted()
                if (uniq.isNotEmpty()) narrow(uniq)?.let { return result(it.first, "alias", 0.80, "known alternative name") }
            }
            byName[nameKey.key]?.let { hit ->
                val compatible = hit.filter { i -> val a = ownCc; val b = entries[i].cc; if (a != null && b != null) a == b else true }
                if (compatible.isEmpty()) return MappingResult(ch.id, null, emptyList(), "noCandidate")
                narrow(compatible)?.let { return result(it.first, "name", minOf(0.89, 0.70 + it.second), "same name") }
                return MappingResult(ch.id, null, emptyList(), "ambiguous")
            }
            ChannelNormalizer.withoutFeedWord(nameKey)?.let { bare ->
                byName[bare.key]?.let { hit ->
                    val compatible = hit.filter { i -> val x = ownCc; val y = entries[i].cc; if (x != null && y != null) x == y else true }
                    if (compatible.isNotEmpty()) narrow(compatible)?.let { return result(it.first, "name", minOf(0.89, 0.65 + it.second), "same name without the feed word") }
                }
            }
            val a = nameKey.tokens.toSet()
            if (a.isEmpty()) return MappingResult(ch.id, null, emptyList(), "noCandidate")
            val shared = HashMap<Int, Int>()
            for (t in a) postings[t]?.let { list -> if (list.size <= commonCutoff) for (k in list) shared[k] = (shared[k] ?: 0) + 1 }
            val best = HashMap<Int, Double>()
            var compared = 0
            for (k in shared.keys.sorted()) {
                compared++
                if (compared > o.maxFuzzyComparisons) break
                val f = flat[k]
                if (f.variant != nameKey.variant) continue
                val ratio = 2.0 * shared[k]!! / (a.size + f.size)
                if (ratio < o.fuzzyMinRatio) continue
                val e = entries[f.entry]
                if (ownCc != null && e.cc != null && ownCc != e.cc) continue
                if (!((ownCc != null && ownCc == e.cc) || (chLang != null && chLang == e.lang))) continue
                best[f.entry] = maxOf(best[f.entry] ?: 0.0, ratio)
            }
            val scored = best.entries.map { it.key to it.value }.sortedWith { x, y -> if (x.second != y.second) y.second.compareTo(x.second) else if (better(x.first, y.first)) -1 else if (better(y.first, x.first)) 1 else 0 }
            val top = scored.firstOrNull() ?: return MappingResult(ch.id, null, emptyList(), "noCandidate")
            fun conf(r: Double) = 0.40 + 0.25 * minOf(1.0, (r - o.fuzzyMinRatio) / (1 - o.fuzzyMinRatio))
            val sugg = scored.take(3).map { GuideMatch(entries[it.first].g.sourceId, entries[it.first].g.xmltvId, "fuzzy", conf(it.second), "similar name") }
            if (scored.size > 1 && entries[scored[1].first].g.xmltvId != entries[top.first].g.xmltvId && top.second - scored[1].second < o.fuzzyMargin) return MappingResult(ch.id, null, sugg, "ambiguous")
            return if (conf(top.second) >= o.autoThreshold) MappingResult(ch.id, sugg[0], emptyList(), null) else MappingResult(ch.id, null, sugg, "belowThreshold")
        }
        return channels.map { mapOne(it, true) }
    }
}
