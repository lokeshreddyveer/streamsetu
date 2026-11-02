package app.streamsetu.core.model

/**
 * The saved rule of a smart collection: a list that fills itself from the library and from what the person has watched. Every field is optional and they all have to hold together.
 * The rule is a plain description (nothing in it is code or SQL); the database turns it into a query with fixed, parameterised conditions (see CollectionRuleSql).
 * It holds no address, no login and no provider URL, so it is safe to share or export.
 */
data class CollectionRule(
    /** Only this connection (by its id). */
    val sourceId: String? = null,
    val yearFrom: Int? = null, val yearTo: Int? = null,
    /** A rating from 0 to 10; titles with no rating do not match. */
    val minRating: Double? = null,
    /** A language name from the known list (Telugu, Hindi ...): found in the title's brackets or the folder's name. */
    val language: String? = null,
    val unwatched: Boolean = false, val favoritesOnly: Boolean = false,
    /** Only what was added in the last this many days. */
    val addedWithinDays: Int? = null,
    /** Words the title must contain (one phrase, any case). */
    val titleContains: String? = null,
    /** Words the folder's name must contain. */
    val folderContains: String? = null,
) {
    /** True when the rule filters nothing (it would be the whole library). */
    val isEmpty get() = this == CollectionRule()

    /** The problems that stop it being saved, in words a person can read; empty when it is fine. */
    fun problems(): List<String> = buildList {
        if (isEmpty) add("Choose at least one thing for the list to match.")
        if (yearFrom != null && yearFrom !in 1870..2200) add("The first year is not a year.")
        if (yearTo != null && yearTo !in 1870..2200) add("The last year is not a year.")
        if (yearFrom != null && yearTo != null && yearFrom > yearTo) add("The first year is after the last.")
        if (minRating != null && minRating !in 0.0..10.0) add("The rating must be between 0 and 10.")
        if (addedWithinDays != null && addedWithinDays !in 1..3650) add("Days must be between 1 and 3650.")
        if (sourceId != null && (sourceId.isBlank() || sourceId.length > 80)) add("The connection is not valid.")
        if (language != null && (language.isBlank() || language.length > 40)) add("The language is not valid.")
        if (titleContains != null && titleContains.isBlank()) add("The title words are empty.")
        if (titleContains != null && titleContains.length > 80) add("The title words are too long.")
        if (folderContains != null && folderContains.length > 80) add("The folder words are too long.")
    }

    /** A short sentence for the list's subtitle: "Telugu · 2020 to 2024 · rating 7+ · unwatched". */
    fun describe(sourceName: ((String) -> String?)? = null): String = listOfNotNull(
        language, when { yearFrom != null && yearTo != null -> if (yearFrom == yearTo) "$yearFrom" else "$yearFrom to $yearTo"; yearFrom != null -> "$yearFrom or later"; yearTo != null -> "$yearTo or earlier"; else -> null },
        minRating?.let { "rating ${if (it % 1.0 == 0.0) it.toInt() else it}+" }, "unwatched".takeIf { unwatched }, "favourites".takeIf { favoritesOnly },
        addedWithinDays?.let { "added in the last $it days" }, titleContains?.let { "title has “$it”" }, folderContains?.let { "folder has “$it”" },
        sourceId?.let { sourceName?.invoke(it)?.let { n -> "from $n" } },
    ).joinToString(" · ").ifBlank { "Everything" }
}

/** A saved smart collection: its own id, a name, which kind of title it holds, and the rule. */
data class SmartCollection(val id: String, val name: String, val scope: ContentKind, val rule: CollectionRule)
