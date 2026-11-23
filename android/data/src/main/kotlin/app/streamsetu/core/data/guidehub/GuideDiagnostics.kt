package app.streamsetu.core.data.guidehub

import app.streamsetu.core.data.db.GuideDiagnosticsEntity

/** Plain-language strings, key for key with the Apple `GuideMessages` (the first part is shared with the freshness model). */
object GuideMessages {
    val text: Map<String, String> = mapOf(
        "guide.off" to "This guide is switched off.", "guide.fresh" to "Guide is up to date.", "guide.neverUpdated" to "This guide has not been downloaded yet.",
        "guide.empty" to "The guide holds no programmes.", "guide.noUpcoming" to "The guide has no upcoming programmes.", "guide.endsUnder3h" to "The guide ends in under 3 hours.",
        "guide.endsIn" to "The guide ends in %d hours and a refresh is overdue.", "guide.updatedLongAgo" to "The guide was last updated %d days ago.",
        "diag.neverFetched" to "Nothing has been downloaded for this guide yet.", "diag.fetchFailed" to "The last download failed: %s",
        "diag.emptyFile" to "The guide file lists channels but contains no programmes. Your provider's guide is empty.", "diag.noChannels" to "The guide file contains no channels or programmes.",
        "diag.allPast" to "Every programme in the guide file has already ended (the newest ended %d days ago). The provider's guide file is out of date; refreshing will not help.",
        "diag.allFuture" to "Every programme in the guide file is further ahead than the days kept. Increase the guide days or check the time zone.",
        "diag.invalidTimes" to "None of the programmes in the guide file has readable times.", "diag.partlyOutside" to "Most programmes in the guide file are outside the days kept (%d of %d).",
        "diag.noMapping" to "The guide has programmes, but none of your channels is matched to it. Match channels in Channel Manager.",
        "diag.fewMapped" to "Only %d of the guide's %d channels are matched to your channels.", "diag.truncated" to "The guide download ended early; the part that arrived is used.",
        "diag.notModified" to "The provider says the guide has not changed since the last download.", "diag.ok" to "The guide looks healthy.",
    )
    private val slot = Regex("%[ds]")
    fun render(key: String, vararg args: Any): String {
        var t = text[key] ?: key
        for (a in args) t = slot.replaceFirst(t, java.util.regex.Matcher.quoteReplacement(a.toString()))
        return t
    }
}

data class GuideFinding(val key: String, val level: FreshLevel, val text: String)

/** What Settings > Guide shows for one source: the last fetch, what it held, what was skipped, and the findings in plain words. */
data class GuideSourceStatus(
    val id: String, val name: String, val kind: String, val enabled: Boolean, val freshness: Freshness, val summary: String, val findings: List<GuideFinding>,
    val storedProgrammes: Int, val mapped: Int,
)

object GuideDiagnosisAdvisor {
    private val DAY = 86_400_000.0

    fun freshness(d: GuideDiagnosticsEntity?, enabled: Boolean, storedProgrammes: Int, windowEnd: Long?, refreshHours: Int, now: Long): Freshness =
        GuideFreshness.evaluate(FreshnessInput(now, enabled, windowEnd, d?.lastSuccess, d?.outcome == "failed" || d?.outcome == "empty", refreshHours * 3600L, storedProgrammes))

    fun findings(d: GuideDiagnosticsEntity?, f: Freshness, now: Long): List<GuideFinding> {
        fun fnd(key: String, level: FreshLevel, vararg a: Any) = GuideFinding(key, level, GuideMessages.render(key, *a))
        if (d == null) return listOf(fnd("diag.neverFetched", FreshLevel.WARNING))
        val out = ArrayList<GuideFinding>()
        if (d.outcome == "failed") out.add(fnd("diag.fetchFailed", FreshLevel.ERROR, d.error ?: "unknown error"))
        if (d.outcome == "notModified") out.add(fnd("diag.notModified", FreshLevel.INFO))
        if (d.outcome == "empty" || (d.outcome == "ok" && d.programmesKept == 0)) {
            when {
                d.programmesSeen == 0 -> out.add(fnd(if (d.channels > 0) "diag.emptyFile" else "diag.noChannels", FreshLevel.ERROR))
                d.droppedInvalid >= d.programmesSeen -> out.add(fnd("diag.invalidTimes", FreshLevel.ERROR))
                d.droppedPast > 0 && d.droppedFuture == 0 -> out.add(fnd("diag.allPast", FreshLevel.ERROR, d.fileLastStop?.let { maxOf(0, Math.round((now - it) / DAY).toInt()) } ?: 0))
                d.droppedFuture > 0 && d.droppedPast == 0 -> out.add(fnd("diag.allFuture", FreshLevel.ERROR))
                else -> out.add(fnd("diag.partlyOutside", FreshLevel.ERROR, d.droppedPast + d.droppedFuture, d.programmesSeen))
            }
        } else if (d.programmesKept > 0) {
            val outside = d.droppedPast + d.droppedFuture
            if (d.programmesSeen > 0 && outside * 10 > d.programmesSeen * 9) out.add(fnd("diag.partlyOutside", FreshLevel.INFO, outside, d.programmesSeen))
            if (d.mapped == 0) out.add(fnd("diag.noMapping", FreshLevel.WARNING))
            else if (d.channels > 0 && d.mapped * 20 < d.channels) out.add(fnd("diag.fewMapped", FreshLevel.INFO, d.mapped, d.channels))
        }
        if (d.truncated) out.add(fnd("diag.truncated", FreshLevel.INFO))
        if (f.level != FreshLevel.FRESH && out.none { it.level == FreshLevel.ERROR }) out.add(GuideFinding(f.key, f.level, GuideMessages.render(f.key, *listOfNotNull(f.amount).toTypedArray())))
        if (out.isEmpty()) out.add(fnd("diag.ok", FreshLevel.FRESH))
        return out.sortedByDescending { it.level.ordinal }
    }
}
