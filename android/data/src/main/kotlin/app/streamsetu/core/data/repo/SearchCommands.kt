package app.streamsetu.core.data.repo

/** Where a typed request can take the person. */
enum class CommandTarget(val title: String, vararg val words: String) {
    DISCOVER("Home", "home", "discover"), LIVE_TV("Live TV", "live tv", "live", "channels"), MOVIES("Movies", "movies", "films"), SERIES("Series", "series", "tv shows", "shows"),
    GUIDE("TV Guide", "tv guide", "guide", "epg", "schedule"), FAVORITES("Favorites", "favourites", "favorites", "favs"), WATCH_LATER("Watch Later", "watch later", "watchlist", "saved"),
    CONTINUE("Continue Watching", "continue watching"), HISTORY("Watch History", "watch history", "history", "recently watched", "recent"), SETTINGS("Settings", "settings", "preferences");

    companion object {
        /** Every phrase with its screen, longest first, so "watch history" is not read as "watch". */
        val synonyms: List<Pair<String, CommandTarget>> = entries.flatMap { t -> t.words.map { it to t } }.sortedByDescending { it.first.length }
    }
}

/** Something the search box can do besides search. */
sealed interface SearchCommand {
    val title: String
    /** Go to a screen; [library] is what to put in that screen's own search box (its filters are read from it there). */
    data class Go(val target: CommandTarget, val library: String? = null) : SearchCommand { override val title get() = library?.let { "Open ${target.title}: $it" } ?: "Go to ${target.title}" }
    data class Play(val name: String) : SearchCommand { override val title get() = "Play “$name”" }
    data object Resume : SearchCommand { override val title get() = "Resume watching" }
    data object LastChannel : SearchCommand { override val title get() = "Play the last channel" }
    data class Favourite(val name: String, val on: Boolean) : SearchCommand { override val title get() = if (on) "Add “$name” to Favorites" else "Remove “$name” from Favorites" }
    data class WatchLater(val name: String, val on: Boolean) : SearchCommand { override val title get() = if (on) "Add “$name” to Watch Later" else "Remove “$name” from Watch Later" }
}

object SearchCommands {
    private val goVerbs = listOf("go to", "open", "show me", "show", "take me to", "switch to", "see", "view", "bring up", "my")
    private val playVerbs = listOf("play", "watch", "put on", "start", "stream")
    private val needsVerb = setOf("live", "saved", "recent", "home", "channels", "shows")
    private val addRe = Regex("""^(?:add|put|save|keep)\s+(.+?)\s+(?:to|in|into|on)\s+(?:my\s+)?(favou?rites?|favs|watch\s?later|watch\s?list)$""")
    private val removeRe = Regex("""^(?:remove|delete|take|drop)\s+(.+?)\s+from\s+(?:my\s+)?(favou?rites?|favs|watch\s?later|watch\s?list)$""")

    /** What the typed words ask for, besides a search. Nothing here changes anything: each is a row the person chooses. */
    fun parse(raw: String): List<SearchCommand> {
        var t = raw.lowercase().replace('’', '\'').trim().trimEnd('.', '!', '?', ',', ';', ':').split(Regex("\\s+")).joinToString(" ")
        if (t.length < 3) return emptyList()
        if (t in setOf("resume", "resume playing", "resume watching", "carry on", "pick up where i left off", "continue where i left off", "continue playing")) return listOf(SearchCommand.Resume)
        if (t in setOf("last channel", "previous channel", "play last channel", "play the last channel", "go to last channel", "back to the last channel")) return listOf(SearchCommand.LastChannel)
        addRe.find(t)?.let { m -> val n = clean(m.groupValues[1], raw); return listOf(if (m.groupValues[2].startsWith("fav")) SearchCommand.Favourite(n, true) else SearchCommand.WatchLater(n, true)) }
        removeRe.find(t)?.let { m -> val n = clean(m.groupValues[1], raw); return listOf(if (m.groupValues[2].startsWith("fav")) SearchCommand.Favourite(n, false) else SearchCommand.WatchLater(n, false)) }
        Regex("""^(?:favou?rite|fav|like)\s+(.+)$""").find(t)?.let { return listOf(SearchCommand.Favourite(clean(it.groupValues[1], raw), true)) }
        Regex("""^(?:unfavou?rite|unfav)\s+(.+)$""").find(t)?.let { return listOf(SearchCommand.Favourite(clean(it.groupValues[1], raw), false)) }

        val out = ArrayList<SearchCommand>()
        destination(t)?.let { out += it }
        val namesAScreen = CommandTarget.synonyms.any { it.first == t }
        if (!namesAScreen) for (v in playVerbs) if (t.startsWith("$v ")) {
            val rest = t.drop(v.length + 1).trim()
            if (rest.length >= 2 && CommandTarget.synonyms.none { it.first == rest } && rest !in setOf("it", "something", "anything")) out += SearchCommand.Play(clean(rest, raw))
            break
        }
        return out
    }

    private fun destination(text: String): SearchCommand? {
        var t = text; var hadVerb = false; var stripped = true
        while (stripped) { stripped = false; for (v in goVerbs) if (t.startsWith("$v ")) { t = t.drop(v.length + 1); hadVerb = true; stripped = true; break } }
        t = t.trim().removePrefix("the ")
        CommandTarget.synonyms.firstOrNull { it.first == t }?.let { (phrase, target) -> return if (!hadVerb && phrase in needsVerb) null else SearchCommand.Go(target) }
        val words = t.split(' ')
        for ((phrase, target) in listOf("movies" to CommandTarget.MOVIES, "films" to CommandTarget.MOVIES, "series" to CommandTarget.SERIES, "shows" to CommandTarget.SERIES, "channels" to CommandTarget.LIVE_TV))
            if (phrase in words && words.size >= 2 && (NaturalQuery.parse(t).isStructured || hadVerb)) return SearchCommand.Go(target, t)
        return null
    }

    /** The title as typed (original capitals), taken from the same place in the original text. */
    private fun clean(lowered: String, original: String): String {
        val o = original.trim(); val i = o.indexOf(lowered, ignoreCase = true)
        return if (i >= 0) o.substring(i, i + lowered.length) else lowered
    }
}

/** What people say instead of a genre ("date night", "with the kids", "binge"). The AI is told about these too, so an unfamiliar phrasing still lands on the same meaning. */
object MoodVocabulary {
    private val phrases = listOf("date night", "with the kids", "with kids", "for kids", "family night", "feel good", "feel-good", "cheer me up", "something light", "make me cry", "tearjerker", "scary", "spooky", "edge of my seat",
        "mind bending", "mind-bending", "twist ending", "laugh out loud", "make me laugh", "true story", "something short", "quick watch", "before bed", "binge", "marathon", "award winning", "award-winning", "hidden gem", "underrated", "easy watch")
    fun understands(text: String): Boolean { val t = " " + text.lowercase() + " "; return phrases.any { t.contains(" $it ") } }
}
