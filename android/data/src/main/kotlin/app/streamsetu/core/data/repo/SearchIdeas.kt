package app.streamsetu.core.data.repo

import java.util.Locale

/** One suggestion shown when the search box is empty: tapping it fills the box. Nothing is sent anywhere until the person searches. */
data class SearchIdea(val label: String, val query: String, val person: Boolean = false)

/**
 * Example searches. The language in them is the person's own: a language of the library, else the audio language chosen in Settings, else the device's language, so a Spanish or Korean library is never
 * shown another region's example. Names are English words (the same words the search understands); [languages] are the library's languages, most common first.
 */
object SearchIdeas {
    val moods: List<SearchIdea> = listOf(
        SearchIdea("Date night", "something for date night"), SearchIdea("With the kids", "a movie with the kids"), SearchIdea("Feel-good", "something feel-good and light"),
        SearchIdea("Edge of my seat", "something gripping, edge of my seat"), SearchIdea("Mind-bending", "a mind-bending sci-fi thriller"), SearchIdea("Make me laugh", "something to make me laugh"),
        SearchIdea("Short one", "something short before bed"), SearchIdea("Binge", "a series to binge this weekend"), SearchIdea("Hidden gem", "a hidden gem I have not watched"),
        SearchIdea("Award-winning", "award winning movies I have not watched"),
    )

    /** The English name of the language a setting value stands for: a name of the language table, or a code of it ("es" is "spanish"); null when unknown. */
    fun preferredName(setting: String?): String? {
        val s = setting?.trim()?.lowercase(Locale.ROOT)?.takeIf { it.isNotEmpty() } ?: return null
        return if (ArtworkMatchDecision.code(s) != null) s else ArtworkMatchDecision.name(s.substringBefore('-').substringBefore('_'))
    }

    /** A library language, else the Settings audio language, else the device's, else english. Lower case. */
    fun exampleLanguage(languages: List<String>, audioSetting: String?, deviceLanguage: String?): String =
        languages.firstOrNull { it.isNotBlank() }?.lowercase(Locale.ROOT) ?: preferredName(audioSetting) ?: preferredName(deviceLanguage) ?: "english"

    fun examples(languages: List<String> = emptyList(), audioSetting: String? = null, deviceLanguage: String? = Locale.getDefault().language): List<SearchIdea> {
        val first = exampleLanguage(languages, audioSetting, deviceLanguage)
        val second = languages.drop(1).firstOrNull { it.isNotBlank() && !it.equals(first, true) }?.lowercase(Locale.ROOT) ?: first
        return listOf(
            SearchIdea("top rated $first movies", "top rated $first movies"),
            SearchIdea("$second movies 2020s, unwatched", "$second movies 2020s unwatched"),
            SearchIdea("newest series", "newest series"),
            SearchIdea("an actor's films: a name, then “movies”", "tom hanks movies", person = true),
            SearchIdea("go to live tv", "go to live tv"),
            SearchIdea("resume", "resume"),
        )
    }
}

/** The languages the person's own library is mostly in (English names, most common first), remembered from the last Home so Settings pickers and example searches can put them first. Only language names are stored, never titles. */
object LibraryLanguageHint {
    private const val FILE = "hints"; private const val KEY = "library.languageHint"
    fun read(context: android.content.Context): List<String> = runCatching { context.getSharedPreferences(FILE, android.content.Context.MODE_PRIVATE).getString(KEY, null)?.split('|')?.filter { it.isNotBlank() } }.getOrNull().orEmpty()
    fun remember(context: android.content.Context, languages: List<String>) {
        val clean = languages.map { it.trim() }.filter { it.isNotEmpty() }.take(8)
        if (clean.isEmpty() || clean == read(context)) return
        runCatching { context.getSharedPreferences(FILE, android.content.Context.MODE_PRIVATE).edit().putString(KEY, clean.joinToString("|")).apply() }
    }

    /** "Any", then the device's language, then the library's detected languages, then every other language alphabetically. [all] = (code, English name). */
    fun pickerOrder(all: List<Pair<String, String>>, device: String, library: List<String>): List<Pair<String, String>> {
        val sorted = all.sortedBy { it.second }
        val first = sorted.filter { it.first == device }
        val detected = library.mapNotNull { n -> sorted.firstOrNull { it.second.equals(n, true) && it.first != device } }.distinct()
        val rest = sorted.filter { l -> l.first != device && detected.none { it.first == l.first } }
        return listOf("" to "Any") + first + detected + rest
    }
}
