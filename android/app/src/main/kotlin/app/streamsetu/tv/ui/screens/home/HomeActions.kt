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
    /** The title may be taken out of recommendations (a movie, a series, or an episode's series; never a channel). */
    val canDismiss: Boolean = true,
    /** The title page can show a cast (a TMDB credential is available). */
    val hasCast: Boolean = false,
    /** The device can share a link to the title (phones). */
    val canShare: Boolean = false,
)

enum class HomeAction {
    PLAY, WATCH_PRIVATELY, RESUME, START_OVER, DETAILS, OPEN_SERIES, CONTINUE_SERIES,
    REMOVE_FROM_CONTINUE, MARK_WATCHED, MARK_UNWATCHED,
    FAVORITE, UNFAVORITE, WATCH_LATER, REMOVE_WATCH_LATER,
    PLAY_NEXT_EPISODE, MARK_SERIES_WATCHED, MARK_SERIES_UNWATCHED,
    CHOOSE_SOURCE, INFO,
    WATCH_CHANNEL, OPEN_GUIDE, OPEN_CHANNEL_FOLDER, REMOVE_FROM_RECENT,
    OPEN_FOLDER, GO_TO_CAST, DONT_RECOMMEND, SHARE,
}

/** Where an action sits in every menu, on every screen and device: play, open, lists, (queue actions), recommendations, share, destructive last. */
enum class MenuGroup { PLAY, OPEN, LIST, QUEUE, RECOMMEND, SHARE, DESTRUCTIVE }

fun HomeAction.group(): MenuGroup = when (this) {
    HomeAction.PLAY, HomeAction.RESUME, HomeAction.WATCH_CHANNEL, HomeAction.OPEN_SERIES, HomeAction.CONTINUE_SERIES, HomeAction.PLAY_NEXT_EPISODE, HomeAction.START_OVER -> MenuGroup.PLAY
    HomeAction.DETAILS, HomeAction.OPEN_FOLDER, HomeAction.GO_TO_CAST, HomeAction.OPEN_GUIDE, HomeAction.OPEN_CHANNEL_FOLDER, HomeAction.CHOOSE_SOURCE, HomeAction.WATCH_PRIVATELY, HomeAction.INFO -> MenuGroup.OPEN
    HomeAction.FAVORITE, HomeAction.UNFAVORITE, HomeAction.WATCH_LATER, HomeAction.REMOVE_WATCH_LATER, HomeAction.MARK_WATCHED, HomeAction.MARK_UNWATCHED, HomeAction.MARK_SERIES_WATCHED, HomeAction.MARK_SERIES_UNWATCHED -> MenuGroup.LIST
    HomeAction.DONT_RECOMMEND -> MenuGroup.RECOMMEND
    HomeAction.SHARE -> MenuGroup.SHARE
    HomeAction.REMOVE_FROM_CONTINUE, HomeAction.REMOVE_FROM_RECENT -> MenuGroup.DESTRUCTIVE
}

/**
 * The one list of actions behind every long press on Home. Only actions that are valid for the card are returned, the safe primary action comes first,
 * and channels never get movie-only actions. A series card never offers "play" (it opens the series; it does not start an arbitrary episode).
 */
fun actionsFor(t: TargetState): List<HomeAction> = baseActions(t).let { base ->
    // The same order everywhere: by group (the safe primary action stays first), then as listed.
    (base + extraActions(t, base)).sortedBy { it.group().ordinal }
}

/** What every menu adds to the per-kind list: open the folder, go to the cast, don't recommend, share. */
private fun extraActions(t: TargetState, base: List<HomeAction>): List<HomeAction> = buildList {
    val title = t.kind == TargetKind.MOVIE || t.kind == TargetKind.SERIES || (t.kind == TargetKind.EPISODE && !t.fromEpisodeList)
    if (title && t.hasFolder && t.kind != TargetKind.EPISODE) add(HomeAction.OPEN_FOLDER)
    if (title && t.hasCast) add(HomeAction.GO_TO_CAST)
    if (title && t.canDismiss) add(HomeAction.DONT_RECOMMEND)
    if (title && t.canShare) add(HomeAction.SHARE)
}

private fun baseActions(t: TargetState): List<HomeAction> = buildList {
    when (t.kind) {
        TargetKind.CHANNEL -> {
            add(HomeAction.WATCH_CHANNEL)
            add(HomeAction.WATCH_PRIVATELY)
            add(if (t.isFavorite) HomeAction.UNFAVORITE else HomeAction.FAVORITE)
            add(if (t.isWatchLater) HomeAction.REMOVE_WATCH_LATER else HomeAction.WATCH_LATER)       // a saved-channel list, not a playback queue: no resume, no watched mark
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
            add(HomeAction.WATCH_PRIVATELY)
            add(if (t.isFavorite) HomeAction.UNFAVORITE else HomeAction.FAVORITE)
            add(if (t.isWatchLater) HomeAction.REMOVE_WATCH_LATER else HomeAction.WATCH_LATER)
            add(if (t.seriesWatched) HomeAction.MARK_SERIES_UNWATCHED else HomeAction.MARK_SERIES_WATCHED)
            if (t.hasVariants) add(HomeAction.CHOOSE_SOURCE)
            add(HomeAction.INFO)
        }
        TargetKind.EPISODE -> if (t.fromEpisodeList) {
            add(if (t.hasResumePoint) HomeAction.RESUME else HomeAction.PLAY)
            add(HomeAction.WATCH_PRIVATELY)
            if (t.hasResumePoint || t.watched) add(HomeAction.START_OVER)
            add(if (t.watched) HomeAction.MARK_UNWATCHED else HomeAction.MARK_WATCHED)
            if (t.hasVariants) add(HomeAction.CHOOSE_SOURCE)
            add(HomeAction.INFO)
        } else {
            add(if (t.hasResumePoint) HomeAction.RESUME else HomeAction.PLAY)
            add(HomeAction.WATCH_PRIVATELY)
            if (t.hasResumePoint || t.watched) add(HomeAction.START_OVER)
            add(HomeAction.DETAILS)
            if (t.inContinue) add(HomeAction.REMOVE_FROM_CONTINUE)
            add(if (t.watched) HomeAction.MARK_UNWATCHED else HomeAction.MARK_WATCHED)
            add(if (t.isFavorite) HomeAction.UNFAVORITE else HomeAction.FAVORITE)
            add(if (t.isWatchLater) HomeAction.REMOVE_WATCH_LATER else HomeAction.WATCH_LATER)
            if (t.hasVariants) add(HomeAction.CHOOSE_SOURCE)
            add(HomeAction.INFO)
        }
        TargetKind.MOVIE -> {
            add(if (t.hasResumePoint) HomeAction.RESUME else HomeAction.PLAY)
            add(HomeAction.WATCH_PRIVATELY)
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
