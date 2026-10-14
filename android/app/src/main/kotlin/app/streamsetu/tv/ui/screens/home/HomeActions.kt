package app.streamsetu.tv.ui.screens.home

/** What a card on Home stands for. */
enum class TargetKind { MOVIE, SERIES, EPISODE, CHANNEL }

/** Where the card sits and what is already true of the title: this decides which actions make sense. */
data class TargetState(
    val kind: TargetKind,
    val inContinue: Boolean = false,
    val inRecentLive: Boolean = false,
    val isFavorite: Boolean = false,
    val isWatchLater: Boolean = false,
    val hasResumePoint: Boolean = false,
    val watched: Boolean = false,
    val hasVariants: Boolean = false,
    val hasGuide: Boolean = false,
    val hasFolder: Boolean = false,
    /** The card is an episode inside a series page: only episode actions apply. */
    val fromEpisodeList: Boolean = false,
    val hasNextEpisode: Boolean = false,
    val seriesWatched: Boolean = false,
)

enum class HomeAction {
    PLAY, RESUME, START_OVER, DETAILS, OPEN_SERIES, CONTINUE_SERIES,
    REMOVE_FROM_CONTINUE, MARK_WATCHED, MARK_UNWATCHED,
    FAVORITE, UNFAVORITE, WATCH_LATER, REMOVE_WATCH_LATER,
    PLAY_NEXT_EPISODE, MARK_SERIES_WATCHED, MARK_SERIES_UNWATCHED,
    CHOOSE_SOURCE, INFO,
    WATCH_CHANNEL, OPEN_GUIDE, OPEN_CHANNEL_FOLDER, REMOVE_FROM_RECENT,
}

/**
 * The one list of actions behind every long press on Home. Only actions that are valid for the card are returned, the safe primary action comes first,
 * and channels never get movie-only actions. A series card never offers "play" (it opens the series; it does not start an arbitrary episode).
 */
fun actionsFor(t: TargetState): List<HomeAction> = buildList {
    when (t.kind) {
        TargetKind.CHANNEL -> {
            add(HomeAction.WATCH_CHANNEL)
            add(if (t.isFavorite) HomeAction.UNFAVORITE else HomeAction.FAVORITE)
            if (t.hasGuide) add(HomeAction.OPEN_GUIDE)
            if (t.hasFolder) add(HomeAction.OPEN_CHANNEL_FOLDER)
            if (t.hasVariants) add(HomeAction.CHOOSE_SOURCE)
            if (t.inRecentLive) add(HomeAction.REMOVE_FROM_RECENT)
            add(HomeAction.INFO)
        }
        TargetKind.SERIES -> {
            add(HomeAction.OPEN_SERIES)
            if (t.inContinue || t.hasResumePoint) add(HomeAction.CONTINUE_SERIES)
            if (t.hasNextEpisode) add(HomeAction.PLAY_NEXT_EPISODE)
            add(if (t.isFavorite) HomeAction.UNFAVORITE else HomeAction.FAVORITE)
            add(if (t.isWatchLater) HomeAction.REMOVE_WATCH_LATER else HomeAction.WATCH_LATER)
            add(if (t.seriesWatched) HomeAction.MARK_SERIES_UNWATCHED else HomeAction.MARK_SERIES_WATCHED)
            if (t.hasVariants) add(HomeAction.CHOOSE_SOURCE)
            add(HomeAction.INFO)
        }
        TargetKind.EPISODE -> if (t.fromEpisodeList) {
            add(if (t.hasResumePoint) HomeAction.RESUME else HomeAction.PLAY)
            if (t.hasResumePoint || t.watched) add(HomeAction.START_OVER)
            add(if (t.watched) HomeAction.MARK_UNWATCHED else HomeAction.MARK_WATCHED)
            if (t.hasVariants) add(HomeAction.CHOOSE_SOURCE)
            add(HomeAction.INFO)
        } else {
            add(if (t.hasResumePoint) HomeAction.RESUME else HomeAction.PLAY)
            if (t.hasResumePoint || t.watched) add(HomeAction.START_OVER)
            add(HomeAction.DETAILS)
            if (t.inContinue) add(HomeAction.REMOVE_FROM_CONTINUE)
            add(if (t.watched) HomeAction.MARK_UNWATCHED else HomeAction.MARK_WATCHED)
            add(if (t.isFavorite) HomeAction.UNFAVORITE else HomeAction.FAVORITE)
            if (t.hasVariants) add(HomeAction.CHOOSE_SOURCE)
            add(HomeAction.INFO)
        }
        TargetKind.MOVIE -> {
            add(if (t.hasResumePoint) HomeAction.RESUME else HomeAction.PLAY)
            if (t.hasResumePoint || t.watched) add(HomeAction.START_OVER)
            add(HomeAction.DETAILS)
            if (t.inContinue) add(HomeAction.REMOVE_FROM_CONTINUE)
            add(if (t.watched) HomeAction.MARK_UNWATCHED else HomeAction.MARK_WATCHED)
            add(if (t.isFavorite) HomeAction.UNFAVORITE else HomeAction.FAVORITE)
            add(if (t.isWatchLater) HomeAction.REMOVE_WATCH_LATER else HomeAction.WATCH_LATER)
            if (t.hasVariants) add(HomeAction.CHOOSE_SOURCE)
            add(HomeAction.INFO)
        }
    }
}

/** The order rows appear in, with the person's hidden rows left out and unknown ids ignored. */
fun visibleRows(order: List<String>, hidden: Set<String>): List<String> = order.filter { it !in hidden }
