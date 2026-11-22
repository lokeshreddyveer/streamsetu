package app.streamsetu.core.data.repo.smartmix

import app.streamsetu.core.model.Folder

/** Folder names for display: the provider's name is never changed (it stays on the folder), only what is drawn. */
object FolderNaming {
    private val prefix = Regex("""^\s*([A-Za-z]{2,3})\s*[|:\-›>]+\s*(.+)$""")
    private val decoration = Regex("""^[\s\p{Punct}\p{So}\p{Sk}★☆●■•─-╿]+""")
    private val trailingCount = Regex("""\s*[(\[]\s*\d[\d,.]*\s*[)\]]\s*$""")
    private val acronyms = setOf("hd", "fhd", "uhd", "sd", "4k", "8k", "hdr", "hdr10", "dv", "3d", "tv", "vod", "uk", "usa", "us", "uae", "hevc", "cam", "dts")
    private val separators = Regex("""\s*[|/]+\s*""")
    private val trailingJunk = Regex("""[\s\p{Punct}\p{So}\p{Sk}\u2605\u2606\u25CF\u25A0\u2022]+$""")

    /** "EN | ACTION MOVIES" becomes "Action Movies · EN"; "★★ KIDS ★★" becomes "Kids"; "Drama (1,204)" becomes "Drama". A name that is only decoration is returned as it was. */
    fun clean(name: String): String {
        var s = name.trim()
        if (s.isEmpty()) return name
        var tag: String? = null
        prefix.matchEntire(s)?.let { m -> if (m.groupValues[1].uppercase() == m.groupValues[1] || m.groupValues[1].length == 2) { tag = m.groupValues[1].uppercase(); s = m.groupValues[2] } }
        s = s.replace(decoration, "").replace(trailingCount, "").replace(trailingJunk, "").trim()
        s = s.replace(separators, " · ")
        if (s.isEmpty()) return name.trim()
        val letters = s.filter { it.isLetter() }
        if (letters.length > 3 && letters.all { it.isUpperCase() }) s = s.split(' ').joinToString(" ") { w -> if (w.length <= 3 && w.all { it.isLetterOrDigit() } && w.any { it.isDigit() }) w else w.lowercase().replaceFirstChar { it.uppercase() } }
        // Quality and format words stay in capitals whatever the case the provider used ("Fhd" -> "FHD").
        s = s.split(' ').joinToString(" ") { w -> if (w.lowercase() in acronyms) w.uppercase() else w }
        return if (tag != null) "$s · $tag" else s
    }
}

/** The order of the folder rows. A pure function of the person's own arrangement, so it is the same every time it is drawn. */
object FolderRowsPlan {
    const val PAGE = 20
    const val RECENT = 3

    /**
     * Hidden folders are left out. Then: pinned, folders the person arranged by hand (their order), the most recently opened ones, folders in the preferred language, and the rest in the
     * provider's order. Locked folders keep their place (their row shows only the name and a lock). [folders] arrive in the person's order already (pinned first, then arranged).
     */
    fun order(folders: List<Folder>, recentOpenedAt: Map<String, Long>, preferredLang: String?, langOf: (Folder) -> String? = { Derive.languageOf("", it.providerName) }): List<Folder> {
        val shown = folders.filter { !it.pref.hidden }
        val pinned = shown.filter { it.pref.pinned }
        val arranged = shown.filter { !it.pref.pinned && it.pref.sortIndex >= 0 }
        val used = HashSet<String>().apply { pinned.forEach { add(it.id) }; arranged.forEach { add(it.id) } }
        val recent = shown.filter { it.id !in used && (recentOpenedAt[it.id] ?: 0L) > 0L }.sortedByDescending { recentOpenedAt[it.id] }.take(RECENT)
        recent.forEach { used.add(it.id) }
        val rest = shown.filter { it.id !in used }
        val pref = preferredLang?.let { Derive.languageName(it) ?: it }
        val (inLang, other) = if (pref == null) emptyList<Folder>() to rest else rest.partition { langOf(it).equals(pref, ignoreCase = true) }
        return pinned + arranged + recent + inLang + other
    }
}
