package app.streamsetu.core.data.smartmix

/** Feature functions, each 0..1000, integers only. */
object Features {
    fun release(year: Int?, nowYear: Int): Int {
        if (year == null) return 300
        val age = maxOf(0, nowYear - year)
        return when {
            age == 0 -> 1000
            age == 1 -> 850
            age == 2 -> 700
            age == 3 -> 560
            age == 4 -> 450
            age == 5 -> 360
            age <= 8 -> 260
            age <= 15 -> 150
            else -> 80
        }
    }

    fun added(addedDays: Int?): Int {
        if (addedDays == null) return 300
        val d = maxOf(0, addedDays)
        return when {
            d <= 7 -> 1000
            d <= 30 -> 800
            d <= 90 -> 600
            d <= 180 -> 450
            d <= 365 -> 300
            else -> 150
        }
    }

    fun quality(rank: Int): Int = when (rank) {
        5 -> 1000; 4 -> 800; 3 -> 600; 2 -> 450; 1 -> 250; else -> 0
    }

    fun language(lang: String?, preferred: String?): Int = when {
        preferred == null -> 500
        lang == null -> 500
        lang == preferred -> 1000
        else -> 150
    }

    /** Tenths of a point from "d", "dd", "d.d", "dd.d", "d.dd", "dd.dd" (ASCII digits only), or null. No float. */
    fun parseTenths(text: String?): Int? {
        if (text == null) return null
        val dot = text.indexOf('.')
        val ip = if (dot < 0) text else text.substring(0, dot)
        val fp = if (dot < 0) "" else text.substring(dot + 1)
        if (ip.length !in 1..2 || !ip.all { it in '0'..'9' }) return null
        if (dot >= 0 && (fp.length !in 1..2 || !fp.all { it in '0'..'9' })) return null
        val tenths = (ip.toInt() * 10) + (if (fp.isEmpty()) 0 else fp[0] - '0')
        return if (tenths in 1..99) tenths else null
    }

    /** Provider ratings are weak evidence: unusable -> neutral 500; usable -> 40% shrink toward neutral. */
    fun rating(text: String?): Int {
        val t = parseTenths(text) ?: return 500
        val raw = (500 + (t - 60) * 12).coerceIn(0, 1000)
        return 500 + ((raw - 500) * 40) / 100
    }

    fun popularity(plays7: Int, plays30: Int): Int {
        val c = plays7.toLong() * 2 + plays30
        return when {
            c <= 0 -> 0
            c == 1L -> 400
            c == 2L -> 600
            c <= 4 -> 750
            c <= 9 -> 900
            else -> 1000
        }
    }

    fun affinity(c: Candidate, a: Affinity): Int {
        var s = 0
        val lang = c.lang
        if (lang != null) {
            if (a.topLangs.isNotEmpty() && a.topLangs[0] == lang) s += 400
            else if (a.topLangs.size > 1 && a.topLangs.subList(1, minOf(3, a.topLangs.size)).contains(lang)) s += 250
        }
        if (c.folderKey != null && a.topFolders.take(5).contains(c.folderKey)) s += 200
        if (c.primaryGenre != null && a.topGenres.take(5).contains(c.primaryGenre)) s += 100
        if (c.year != null && a.topDecades.take(2).contains(Math.floorDiv(c.year, 10) * 10)) s += 150
        return minOf(1000, s)
    }

    fun fresh(loadsAgo: Int?): Int = when (loadsAgo) {
        null -> 1000
        1 -> 100
        2 -> 400
        3 -> 700
        else -> 1000
    }
}
