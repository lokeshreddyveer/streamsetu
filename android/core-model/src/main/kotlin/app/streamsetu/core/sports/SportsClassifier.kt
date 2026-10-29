package app.streamsetu.core.sports

import java.text.Normalizer

/**
 * Decides, from a guide programme and its channel alone, whether it is a real sports event, and what shape: two sides, a race session, a round of a tournament, a fight card, or (only when the
 * competition and a specific final or match number are named) a generic event. Deterministic: the same input always gives the same answer; nothing is learned or fetched. Studio shows, news,
 * highlights, documentaries, replays and "sports channel" listings are not events, and a listing that only says "Cricket Live" is skipped rather than guessed at. Mirrors the Swift SportsClassifier.
 */
object SportsClassifier {
    data class Hint(val value: String, val source: MetadataSource)

    data class Match(
        val sport: Sport,
        val kind: SportsEventKind,
        val competition: String?,
        val participants: List<String>,
        val stage: String?,
        val title: String,
        val language: Hint?,
        val quality: Hint?,
        val variant: String?,
        val confidence: Double,
        /** What two feeds of the same event share. For two sides it does not depend on their order, so "A vs B" and "B @ A" are one event. */
        val identity: String,
        val competitionKey: String?,
    )

    private class Vocab(val competitions: List<String>, val words: List<String>)

    private val vocabulary: Map<Sport, Vocab> = mapOf(
        Sport.FOOTBALL to Vocab(listOf("premier league", "la liga", "laliga", "serie a", "bundesliga", "ligue 1", "eredivisie", "champions league", "europa league", "conference league", "mls", "fa cup", "carabao cup",
            "copa del rey", "copa america", "copa libertadores", "nations league", "concacaf", "afcon", "liga mx", "scottish premiership", "isl", "a league", "uefa", "fifa", "efl cup", "dfb pokal",
            "coppa italia", "super lig", "saudi pro league", "club world cup"), listOf("soccer", "football")),
        Sport.CRICKET to Vocab(listOf("ipl", "t20", "t20i", "odi", "test match", "the ashes", "ashes", "bbl", "big bash", "psl", "cpl", "the hundred", "county championship", "ranji trophy", "wpl", "sa20", "ilt20",
            "icc", "asia cup", "bpl", "lpl", "champions trophy"), listOf("cricket")),
        Sport.BASKETBALL to Vocab(listOf("nba", "wnba", "euroleague", "ncaab", "fiba", "g league", "nbl", "liga acb"), listOf("basketball")),
        Sport.AMERICAN_FOOTBALL to Vocab(listOf("nfl", "ncaaf", "college football", "super bowl", "cfl", "xfl", "ufl"), listOf("american football")),
        Sport.BASEBALL to Vocab(listOf("mlb", "npb", "kbo", "world series", "ncaa baseball"), listOf("baseball")),
        Sport.ICE_HOCKEY to Vocab(listOf("nhl", "khl", "stanley cup", "ahl", "shl", "iihf"), listOf("ice hockey")),
        Sport.TENNIS to Vocab(listOf("atp", "wta", "wimbledon", "roland garros", "french open", "australian open", "us open", "grand slam", "davis cup", "billie jean king cup", "laver cup", "itf", "atp finals",
            "wta finals"), listOf("tennis")),
        Sport.MOTORSPORT to Vocab(listOf("formula 1", "formula one", "f1", "formula 2", "formula 3", "f2", "f3", "formula e", "motogp", "moto2", "moto3", "nascar", "indycar", "wrc", "world endurance", "wec",
            "le mans", "dtm", "superbike", "wsbk", "supercars", "grand prix", "rally"), listOf("motorsport", "motorsports")),
        Sport.GOLF to Vocab(listOf("pga", "lpga", "pga tour", "liv golf", "ryder cup", "solheim cup", "presidents cup", "the open", "open championship", "dp world tour", "the masters", "augusta", "us open golf",
            "masters tournament"), listOf("golf")),
        Sport.BOXING to Vocab(listOf("wbc", "wba", "ibf", "wbo", "title fight"), listOf("boxing")),
        Sport.MMA to Vocab(listOf("ufc", "bellator", "pfl", "one championship", "cage warriors", "ksw", "ufc fight night"), listOf("mma", "mixed martial arts")),
        Sport.RUGBY to Vocab(listOf("six nations", "rugby championship", "super rugby", "premiership rugby", "urc", "top 14", "nrl", "heineken champions cup", "rugby world cup", "gallagher premiership", "pro d2",
            "rugby league"), listOf("rugby")),
    )
    private val allVocabulary: Set<String> = vocabulary.values.flatMap { it.competitions + it.words }.toSet()
    /** A competition word that does not say which series it is (every motorsport has a Grand Prix); it counts as evidence of the sport but is not used as the competition. */
    private val weakCompetitions = setOf("grand prix", "rally", "the open", "icc")
    private val singleEvents = setOf("super bowl", "the ashes")

    private val notAnEvent = setOf("news", "magazine", "highlights", "highlight", "review", "preview", "analysis", "documentary", "docuseries", "studio", "talk", "podcast", "show", "daily", "weekly", "best of",
        "classic", "classics", "greatest", "story", "stories", "history", "inside", "behind the scenes", "countdown", "pre match", "post match", "prematch", "postmatch", "pregame", "postgame", "replay", "repeat",
        "rerun", "re run", "encore", "on demand", "archive", "archived", "condensed", "goals", "bulletin", "report", "reports", "debate", "extra time", "lounge", "tonight", "roundup", "round up", "recap",
        "reaction", "verdict", "special report", "full match replay", "movie", "film", "game show", "weigh in", "press conference")
    private val notAnEventCategory = listOf("news", "documentary", "movie", "film", "series", "talk", "magazine", "reality", "drama", "comedy", "cartoon", "kids", "children", "entertainment")
    private val stageWords = setOf("round", "final", "finals", "semifinal", "quarterfinal", "semi", "quarter", "race", "qualifying", "practice", "sprint", "stage", "day", "card", "prelims", "main", "event",
        "qualifier", "heat", "fp1", "fp2", "fp3", "matchday", "leg", "group", "week", "session")

    private val languages = mapOf("english" to "en", "spanish" to "es", "espanol" to "es", "french" to "fr", "francais" to "fr", "german" to "de", "deutsch" to "de", "arabic" to "ar", "hindi" to "hi", "telugu" to "te",
        "tamil" to "ta", "kannada" to "kn", "malayalam" to "ml", "bengali" to "bn", "marathi" to "mr", "urdu" to "ur", "punjabi" to "pa", "portuguese" to "pt", "italian" to "it", "turkish" to "tr", "russian" to "ru",
        "polish" to "pl", "dutch" to "nl", "persian" to "fa", "farsi" to "fa", "mandarin" to "zh", "chinese" to "zh", "japanese" to "ja", "korean" to "ko", "thai" to "th", "indonesian" to "id", "en" to "en",
        "es" to "es", "fr" to "fr", "de" to "de", "ar" to "ar", "hi" to "hi", "te" to "te", "ta" to "ta", "pt" to "pt", "it" to "it", "tr" to "tr", "ru" to "ru", "pl" to "pl", "nl" to "nl")
    private val qualities = mapOf("4k" to "4K", "uhd" to "4K", "2160p" to "4K", "fhd" to "FHD", "1080p" to "FHD", "1080i" to "FHD", "hd" to "HD", "720p" to "HD", "hevc" to "HD", "sd" to "SD", "576p" to "SD", "480p" to "SD")
    private val variants = mapOf("home" to "home", "away" to "away", "alt" to "alt", "alternate" to "alt", "clean" to "clean")
    private val plainTags = setOf("live", "new", "feed", "commentary", "multi", "audio", "main", "world", "international", "stream", "channel", "hdr", "dolby", "the", "from")
    private val strongSeparators = listOf(" vs. ", " vs ", " v. ", " v ", " @ ", " versus ")

    private class Tags(var language: String? = null, var quality: String? = null, var variant: String? = null) {
        fun merge(o: Tags) { language = language ?: o.language; quality = quality ?: o.quality; variant = variant ?: o.variant }
    }

    /**
     * Null when the programme is not a clear sports event. `fastReject = false` skips the early refusal and takes the full path (the reference the shortcut is tested against).
     * [channelLanguage] and [channelQuality] are what the playlist itself says (the provider); anything read out of a name is marked as a hint.
     * The Android channel model has neither, so they are null there.
     */
    fun classify(title: String, subtitle: String? = null, category: String? = null, channelName: String = "", channelCategory: String? = null, channelLanguage: String? = null, channelQuality: String? = null, fastReject: Boolean = true): Match? {
        if (title.isEmpty() || title.length > 200) return null
        // Cheap early refusal for the great majority of listings: an event has two sides (a separator) or names a sport or competition in its own title.
        val lower = title.lowercase()
        if (fastReject && !hasSeparator(lower) && phrases(tokens(fold(lower)), 3).none { it in allVocabulary }) return null
        val cat = fold(category.orEmpty())
        if (notAnEventCategory.any { cat.contains(it) }) return null

        val tags = Tags()
        var text = cleaned(title, tags)
        if (separatorRange(text) == null && !subtitle.isNullOrEmpty()) {
            val subTags = Tags(); val s = cleaned(subtitle, subTags)
            if (separatorRange(s) != null) { text = "$text: $s"; tags.merge(subTags) }
        }
        val words = tokens(fold(text))
        if (words.isEmpty() || containsAny(notAnEvent, words)) return null

        val nameTags = Tags(); cleaned(channelName, nameTags)
        val language = pick(channelLanguage?.let { languageCode(it) }, tags.language, nameTags.language)
        val quality = pick(channelQuality?.let { qualityCode(it) }, tags.quality, nameTags.quality)
        val found = detectSport(words, tokens(listOf(fold(text), cat, fold(channelCategory.orEmpty())).joinToString(" ")), tokens(fold(channelName))) ?: return null

        fun build(kind: SportsEventKind, competition: String?, participants: List<String>, stage: String?, title: String, identity: String, confidence: Double) =
            Match(found.sport, kind, competition, participants, stage, title, language, quality, tags.variant, confidence, identity, competition?.let { teamKey(it) }?.ifEmpty { null })

        // 1. two sides
        splitSides(text)?.let { sides ->
            var c = if (found.fromCompetition) 0.95 else if (found.fromTitle) 0.85 else 0.7
            if (!sides.strong) c -= 0.1
            val identity = "${found.sport.name.lowercase()}|h2h|" + sides.participants.map { teamKey(it) }.sorted().joinToString("|")
            return build(SportsEventKind.HEAD_TO_HEAD, sides.competition ?: found.competition, sides.participants, null, sides.participants.joinToString(" vs "), identity, c)
        }

        // 2. an event without two sides: by the sport
        if (!(found.fromTitle || found.fromCompetition)) return null
        val stage = stageOf(found.sport, words)
        val name = eventName(words, found.keyword)
        val sportKey = found.sport.name.lowercase()
        return when (found.sport) {
            Sport.MOTORSPORT -> {
                if (name.isEmpty() || !(stage != null || found.keyword == "grand prix" || ("grand" in words && "prix" in words))) return null
                val st = stage ?: "race"
                build(SportsEventKind.RACE_SESSION, found.competition, emptyList(), st, collapse(text), "motorsport|race|$name|$st", if (stage == null) 0.65 else 0.85)
            }
            Sport.GOLF, Sport.TENNIS -> {
                val st = stage ?: return null
                if (name.isEmpty() && !found.fromCompetition) return null
                val n = name.ifEmpty { found.keyword.orEmpty() }
                build(SportsEventKind.TOURNAMENT_ROUND, found.competition, emptyList(), st, collapse(text), "$sportKey|round|$n|$st", if (found.fromCompetition) 0.85 else 0.7)
            }
            Sport.BOXING, Sport.MMA -> {
                val numbered = words.any { w -> w.all { it.isDigit() } && w.length >= 2 }
                if (!(found.fromCompetition || numbered) || !(name.isNotEmpty() || numbered) || !(stage != null || numbered)) return null
                build(SportsEventKind.FIGHT_CARD, found.competition, emptyList(), stage, collapse(text), "$sportKey|card|$name|${stage.orEmpty()}", if (found.fromCompetition) 0.85 else 0.7)
            }
            else -> {
                val keyword = found.keyword
                if (!found.fromCompetition || keyword == null) return null
                val st = genericStage(words)
                if (st == null && keyword !in singleEvents) return null
                build(SportsEventKind.GENERIC, found.competition, emptyList(), st, collapse(text), "$sportKey|generic|$name|${st.orEmpty()}", 0.7)
            }
        }
    }

    private fun pick(provider: String?, title: String?, name: String?): Hint? =
        provider?.let { Hint(it, MetadataSource.PROVIDER) } ?: (title ?: name)?.let { Hint(it, MetadataSource.PARSED_FROM_NAME) }

    // ---- tags

    /** Removes "(HD)", "[English]", "| FHD", "- Home Feed", "LIVE:" and trailing quality or language words, remembering what they said. */
    private fun cleaned(raw: String, tags: Tags): String {
        var s = raw.trim()
        for (lead in listOf("🔴", "●", "live:", "live -", "live |", "live from", "live –", "live —", "live")) {
            if (s.lowercase().startsWith(lead) && (lead != "live" || s.drop(4).firstOrNull() == ' ')) { s = s.drop(lead.length).trim { it.isWhitespace() || it in ":-|–—" }; break }
        }
        while (true) {
            val open = s.indexOfFirst { it == '(' || it == '[' }; if (open < 0) break
            val close = s.indexOfFirst { it == ')' || it == ']' }.let { if (it > open) it else -1 }; if (close < 0) break
            val inner = s.substring(open + 1, close)
            if (isOnlyTags(inner)) { absorb(inner, tags); s = s.removeRange(open, close + 1) } else break
        }
        for (sep in listOf(" | ", " – ", " — ", " - ")) {
            while (true) {
                val i = s.lastIndexOf(sep); if (i < 0 || !isOnlyTags(s.substring(i + sep.length))) break
                absorb(s.substring(i + sep.length), tags); s = s.substring(0, i)
            }
        }
        val parts = s.split(' ').filter { it.isNotEmpty() }.toMutableList()
        while (parts.isNotEmpty() && isTag(parts.last())) { absorb(parts.last(), tags); parts.removeAt(parts.size - 1) }
        return collapse(parts.joinToString(" "))
    }
    private fun isTag(word: String): Boolean { val w = fold(word); return w in languages || w in qualities || w in variants || w in plainTags }
    private fun isOnlyTags(s: String): Boolean { val ws = tokens(fold(s)); return ws.isNotEmpty() && ws.all { it in languages || it in qualities || it in variants || it in plainTags } }
    private fun absorb(s: String, tags: Tags) {
        for (w in tokens(fold(s))) {
            languages[w]?.let { if (tags.language == null) tags.language = it }
            qualities[w]?.let { if (tags.quality == null) tags.quality = it }
            variants[w]?.let { if (tags.variant == null) tags.variant = it }
        }
    }
    fun languageCode(s: String): String? = languages[fold(s)] ?: fold(s).takeIf { it.length == 2 }
    fun qualityCode(s: String): String? = tokens(fold(s)).firstNotNullOfOrNull { qualities[it] }

    // ---- sport

    private class Found(val sport: Sport, val competition: String?, val keyword: String?, val fromCompetition: Boolean, var fromTitle: Boolean)

    private fun detectSport(titleWords: List<String>, evidenceWords: List<String>, channelWords: List<String>): Found? {
        fun hit(words: List<String>): Found? {
            val set = phrases(words, 3)
            var best: Triple<Int, Sport, Pair<String, Boolean>>? = null
            for (sport in Sport.values()) {
                val v = vocabulary[sport] ?: continue
                for (k in v.competitions) if (k in set) { val s = (if (k in weakCompetitions) 500 else 1000) + k.length; if (best == null || s > best.first) best = Triple(s, sport, k to true) }
                for (k in v.words) if (k in set) { val s = k.length; if (best == null || s > best.first) best = Triple(s, sport, k to false) }
            }
            val b = best ?: return null
            val (keyword, isCompetition) = b.third
            return Found(b.second, if (isCompetition && keyword !in weakCompetitions) display(keyword) else null, keyword, isCompetition, true)
        }
        hit(titleWords)?.let { return it }
        hit(evidenceWords)?.let { return Found(it.sport, it.competition, it.keyword, it.fromCompetition, false) }
        hit(channelWords)?.let { return Found(it.sport, null, it.keyword, false, false) }
        return null
    }

    private val upper = setOf("nba", "nfl", "nhl", "mlb", "ipl", "ufc", "pga", "atp", "wta", "mls", "uefa", "fifa", "icc", "wbc", "wba", "ibf", "wbo", "pfl", "wrc", "dtm", "t20", "odi", "f1", "f2", "f3", "bbl",
        "psl", "cpl", "wpl", "khl", "ahl", "shl", "nrl", "urc", "isl", "ksw", "npb", "kbo", "cfl", "xfl", "ufl", "wnba", "ncaab", "ncaaf", "lpga", "motogp")
    private fun display(keyword: String) = if (keyword in upper) keyword.uppercase() else keyword.split(' ').joinToString(" ") { it.replaceFirstChar { c -> c.uppercase() } }

    // ---- stages and names

    private fun stageOf(sport: Sport, w: List<String>): String? {
        val set = phrases(w, 3)
        fun numberAfter(word: String): String? { val i = w.indexOf(word); return if (i >= 0 && i + 1 < w.size && w[i + 1].all { it.isDigit() }) w[i + 1] else null }
        return when (sport) {
            Sport.MOTORSPORT -> when {
                "sprint qualifying" in set || "sprint shootout" in set -> "sprint qualifying"
                "sprint" in w -> "sprint"
                "qualifying" in w -> "qualifying"
                "fp1" in w -> "practice 1"; "fp2" in w -> "practice 2"; "fp3" in w -> "practice 3"
                "practice" in w -> numberAfter("practice")?.let { "practice $it" } ?: "practice"
                "race" in w -> "race"
                else -> null
            }
            Sport.GOLF, Sport.TENNIS -> when {
                "final round" in set -> "final round"
                numberAfter("round") != null -> "round ${numberAfter("round")}"
                numberAfter("day") != null -> "day ${numberAfter("day")}"
                "semi final" in set || "semifinal" in w || "semifinals" in w -> "semi-final"
                "quarter final" in set || "quarterfinal" in w || "quarterfinals" in w -> "quarter-final"
                "final" in w || "finals" in w -> "final"
                "qualifying" in w -> "qualifying"
                else -> null
            }
            Sport.BOXING, Sport.MMA -> when {
                "early prelims" in set -> "early prelims"
                "prelims" in w -> "prelims"
                "main card" in set -> "main card"
                "main event" in set -> "main event"
                "fight night" in set -> "fight night"
                else -> null
            }
            else -> null
        }
    }

    private fun genericStage(w: List<String>): String? {
        val set = phrases(w, 2)
        for (s in listOf("semi final", "quarter final", "final", "qualifier", "playoff", "opening ceremony")) if (s in set) return s
        for (noun in listOf("match", "game", "test")) { val i = w.indexOf(noun); if (i >= 0 && i + 1 < w.size && w[i + 1].all { it.isDigit() }) return "$noun ${w[i + 1]}" }
        return null
    }

    private val fillerWords = setOf("live", "the", "of", "at", "in", "round", "day", "final", "finals", "semi", "quarter", "race", "qualifying", "practice", "sprint", "shootout", "fp1", "fp2", "fp3", "main",
        "card", "event", "prelims", "early", "fight", "night", "tournament", "championship", "highlights")
    private val sportWords: Set<String> = vocabulary.values.flatMap { it.words }.flatMap { it.split(' ') }.toSet()

    /** What names the event once the competition, the stage and the filler are taken away ("monaco grand prix", "ufc 300", "mens singles"). */
    private fun eventName(words: List<String>, competition: String?): String {
        val drop = HashSet(fillerWords + sportWords)
        if (competition != null && competition !in weakCompetitions) competition.split(' ').forEach { drop.add(it) }
        val out = ArrayList<String>()
        for ((i, w) in words.withIndex()) {
            if (w in drop) continue
            if (w.all { it.isDigit() } && i > 0 && words[i - 1] in setOf("practice", "round", "day")) continue
            out.add(w)
        }
        return out.joinToString(" ")
    }

    private fun phrases(words: List<String>, upTo: Int): Set<String> {
        val set = HashSet<String>()
        for (len in 1..upTo) if (words.size >= len) for (i in 0..words.size - len) set.add(words.subList(i, i + len).joinToString(" "))
        return set
    }
    private fun containsAny(list: Set<String>, words: List<String>) = phrases(words, 3).any { it in list }

    // ---- sides

    private fun hasSeparator(lower: String) = listOf(" vs", " v ", " v.", " @ ", " versus ", " - ", " – ", " — ").any { lower.contains(it) }

    private fun separatorRange(s: String): Triple<Int, Int, Boolean>? {
        var best: Triple<Int, Int, Boolean>? = null
        for (sep in strongSeparators) {
            val i = s.indexOf(sep, ignoreCase = true)
            if (i >= 0 && (best == null || i < best.first)) best = Triple(i, i + sep.length, sep == " @ ")
        }
        return best
    }

    private class Sides(val participants: List<String>, val competition: String?, val strong: Boolean)

    private fun splitSides(text: String): Sides? {
        var competition: String? = null; var strong = true; val left: String; val right: String; var isAt = false
        val sep = separatorRange(text)
        if (sep != null) {
            var l = text.substring(0, sep.first)
            lastPrefixSeparator(l)?.let { (from, to) -> competition = collapse(l.substring(0, from)); l = l.substring(to) }
            left = l; right = trimTail(text.substring(sep.second)); isAt = sep.third
        } else {
            val parts = text.split(" - ").flatMap { it.split(" – ") }.map { collapse(it) }.filter { it.isNotEmpty() }
            when (parts.size) {
                2 -> { left = parts[0]; right = trimTail(parts[1]) }
                3 -> { competition = parts[0]; left = parts[1]; right = trimTail(parts[2]) }
                else -> return null
            }
            strong = false
            if (tokens(fold(parts.joinToString(" "))).any { it in stageWords }) return null       // "Monaco Grand Prix - Race" is an event and its stage, not two sides
        }
        val a = collapse(left); val b = collapse(right)
        if (!plausibleSide(a) || !plausibleSide(b) || fold(a) == fold(b)) return null
        return Sides(if (isAt) listOf(b, a) else listOf(a, b), competition?.ifEmpty { null }, strong)         // "away @ home" lists the home side first
    }

    private fun lastPrefixSeparator(s: String): Pair<Int, Int>? {
        var best: Pair<Int, Int>? = null
        for (sep in listOf(": ", " | ", " – ", " — ", " - ")) { val i = s.lastIndexOf(sep); if (i >= 0 && (best == null || i > best.first)) best = i to i + sep.length }
        return best
    }
    private fun trimTail(s: String): String { var out = s; for (sep in listOf(" | ", " – ", " — ", " - ", ": ", " (")) { val i = out.indexOf(sep); if (i >= 0) out = out.substring(0, i) }; return collapse(out) }
    private fun plausibleSide(s: String): Boolean {
        val t = tokens(fold(s))
        if (t.size !in 1..6 || s.length !in 2..60 || t.all { w -> w.all { it.isDigit() } }) return false
        return !containsAny(notAnEvent, t)
    }

    // ---- text

    fun fold(s: String): String = Normalizer.normalize(s, Normalizer.Form.NFD).replace(Regex("\\p{Mn}+"), "").lowercase()
    private fun collapse(s: String) = s.split(' ', '\t', '\n').filter { it.isNotEmpty() }.joinToString(" ").trim { it in " -–—:|·" }
    private fun tokens(s: String) = s.split(Regex("[^\\p{L}\\p{N}]+")).filter { it.isNotEmpty() }

    /** A side's or competition's name for comparing: no accents, case, punctuation or club markers. */
    fun teamKey(s: String): String { val drop = setOf("fc", "cf", "afc", "sc", "ac", "cd", "club", "the"); return tokens(fold(s)).filter { it !in drop }.joinToString(" ") }
}
