package app.streamsetu.tv.ui.screens.search

import app.streamsetu.core.data.repo.GlobalResults
import app.streamsetu.core.data.repo.SearchItem
import app.streamsetu.core.data.repo.SearchKind
import app.streamsetu.core.data.repo.SearchResultOrder
import app.streamsetu.core.data.repo.SportsSearchOrder
import app.streamsetu.core.data.repo.SearchText

/** Whether Sports results are looked up at all: only when the Sports switch is on, the screen can open them, and the whole library is being searched. */
internal fun sportsSearchActive(enabled: Boolean, canOpen: Boolean, allTypes: Boolean, allTab: Boolean): Boolean = enabled && canOpen && allTypes && allTab

/** The decisions Search makes about what to show first and where the remote goes, kept apart from the screen so they can be tested. */

/** What the Search body is showing. One value, so the screen never has to work it out from several flags. */
internal enum class SearchPhase { IDLE, LOADING, RESULTS, EMPTY, FAILED }

/**
 * IDLE: nothing typed. LOADING: looking, with nothing to show yet (also while a lookup that found nothing so far is still running). RESULTS: something to show (a late failure of one slow
 * source is a note above the results, not a replacement of them). EMPTY: the search finished and found nothing. FAILED: it could not finish and there is nothing to show.
 */
internal fun searchPhase(blank: Boolean, results: GlobalResults?, searching: Boolean, failed: Boolean, otherResults: Boolean = false): SearchPhase = when {
    blank -> SearchPhase.IDLE
    results != null && (!results.isEmpty || otherResults) -> SearchPhase.RESULTS
    failed -> SearchPhase.FAILED
    results == null || searching -> SearchPhase.LOADING
    else -> SearchPhase.EMPTY
}

/** The one order the groups are drawn in. Best Match and the focus after Done use it too, so the first thing named is the first thing shown. */
internal val shownOrder: List<SearchKind> get() = SearchResultOrder + SportsSearchOrder

/** The result whose title is exactly what was typed (ignoring case and accents), looked for in every kind of result. */
internal fun bestMatchOf(results: GlobalResults, query: String): SearchItem? {
    val typed = SearchText.normalize(query.trim())
    return shownOrder.flatMap { results.byKind[it].orEmpty() }.firstOrNull { SearchText.normalize(it.title) == typed }
}

/** A group's rows without the best match, which is already shown above them: the same title is never listed twice. */
internal fun withoutBest(rows: List<SearchItem>, best: SearchItem?): List<SearchItem> = if (best == null) rows else rows.filter { it.id != best.id }

/** Where the remote goes after the keyboard's Done: the exact match, else the first result in the order the groups are shown. */
internal fun doneResultId(results: GlobalResults, query: String): String? =
    (bestMatchOf(results, query) ?: shownOrder.firstNotNullOfOrNull { results.byKind[it].orEmpty().firstOrNull() })?.id

internal enum class DoneStep { RESULT, ACTION }

/** The order of places to try after Done: a result the words found comes first, then the first command or Ask AI; with no result, only the command or Ask AI. */
internal fun doneSteps(hasResult: Boolean): List<DoneStep> = if (hasResult) listOf(DoneStep.RESULT, DoneStep.ACTION) else listOf(DoneStep.ACTION)
