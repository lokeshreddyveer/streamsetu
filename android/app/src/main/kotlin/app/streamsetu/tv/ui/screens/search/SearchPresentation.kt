package app.streamsetu.tv.ui.screens.search

import app.streamsetu.core.data.repo.GlobalResults
import app.streamsetu.core.data.repo.SearchItem
import app.streamsetu.core.data.repo.SearchKind
import app.streamsetu.core.data.repo.SearchText

/** The decisions Search makes about what to show first and where the remote goes, kept apart from the screen so they can be tested. */

/** The result whose title is exactly what was typed (ignoring case and accents), looked for in every kind of result. */
internal fun bestMatchOf(results: GlobalResults, query: String): SearchItem? {
    val typed = SearchText.normalize(query.trim())
    return SearchKind.entries.flatMap { results.byKind[it].orEmpty() }.firstOrNull { SearchText.normalize(it.title) == typed }
}

/** A group's rows without the best match, which is already shown above them: the same title is never listed twice. */
internal fun withoutBest(rows: List<SearchItem>, best: SearchItem?): List<SearchItem> = if (best == null) rows else rows.filter { it.id != best.id }

/** Where the remote goes after the keyboard's Done: the exact match, else the first result in the order the groups are shown. */
internal fun doneResultId(results: GlobalResults, query: String): String? =
    (bestMatchOf(results, query) ?: SearchKind.entries.firstNotNullOfOrNull { results.byKind[it].orEmpty().firstOrNull() })?.id

internal enum class DoneStep { RESULT, ACTION }

/** The order of places to try after Done: a result the words found comes first, then the first command or Ask AI; with no result, only the command or Ask AI. */
internal fun doneSteps(hasResult: Boolean): List<DoneStep> = if (hasResult) listOf(DoneStep.RESULT, DoneStep.ACTION) else listOf(DoneStep.ACTION)
