package app.streamsetu.tv

import app.streamsetu.tv.ui.screens.home.*
import org.junit.Assert.*
import org.junit.Test

class HomeActionsTests {
    @Test fun channelsNeverGetMovieActions() {
        val a = actionsFor(TargetState(TargetKind.CHANNEL, inRecentLive = true, hasGuide = true, hasFolder = true))
        assertFalse(HomeAction.MARK_WATCHED in a); assertFalse(HomeAction.START_OVER in a); assertFalse(HomeAction.RESUME in a)
        assertTrue(HomeAction.WATCH_LATER in a)          // a saved-channel list: it is allowed, but there is no resume and no watched mark
        assertEquals(HomeAction.WATCH_CHANNEL, a.first()); assertTrue(HomeAction.OPEN_GUIDE in a && HomeAction.REMOVE_FROM_RECENT in a)
    }
    @Test fun guideActionOnlyWhenThereIsGuideData() = assertFalse(HomeAction.OPEN_GUIDE in actionsFor(TargetState(TargetKind.CHANNEL, hasGuide = false)))
    @Test fun aSeriesCardOpensTheSeriesAndNeverPlaysAnEpisode() {
        val a = actionsFor(TargetState(TargetKind.SERIES))
        assertEquals(HomeAction.OPEN_SERIES, a.first()); assertFalse(HomeAction.PLAY in a); assertFalse(HomeAction.RESUME in a)
    }
    @Test fun aMovieInProgressOffersResumeStartOverAndRemoveFromContinue() {
        val a = actionsFor(TargetState(TargetKind.MOVIE, inContinue = true, hasResumePoint = true))
        assertEquals(HomeAction.RESUME, a.first()); assertTrue(HomeAction.START_OVER in a && HomeAction.REMOVE_FROM_CONTINUE in a); assertFalse(HomeAction.PLAY in a)
    }
    @Test fun aFreshMovieOffersPlayAndNoStartOver() {
        val a = actionsFor(TargetState(TargetKind.MOVIE)); assertEquals(HomeAction.PLAY, a.first()); assertFalse(HomeAction.START_OVER in a); assertFalse(HomeAction.REMOVE_FROM_CONTINUE in a)
    }
    @Test fun favoriteAndWatchLaterFlipWithTheirState() {
        val a = actionsFor(TargetState(TargetKind.MOVIE, isFavorite = true, isWatchLater = true))
        assertTrue(HomeAction.UNFAVORITE in a && HomeAction.REMOVE_WATCH_LATER in a); assertFalse(HomeAction.FAVORITE in a || HomeAction.WATCH_LATER in a)
    }
    @Test fun watchedTitlesOfferMarkUnwatched() = assertTrue(HomeAction.MARK_UNWATCHED in actionsFor(TargetState(TargetKind.MOVIE, watched = true)))
    @Test fun chooseSourceOnlyWhenAlternativesExist() {
        assertFalse(HomeAction.CHOOSE_SOURCE in actionsFor(TargetState(TargetKind.MOVIE)))
        assertTrue(HomeAction.CHOOSE_SOURCE in actionsFor(TargetState(TargetKind.MOVIE, hasVariants = true)))
    }
    @Test fun hiddenRowsAreLeftOutAndTheOrderIsKept() = assertEquals(listOf("continue", "movies"), visibleRows(listOf("continue", "live", "movies"), setOf("live")))

    @Test fun seriesMenuHasPlayNextAndMarkSeriesOnlyWhenTheyApply() {
        val a = actionsFor(TargetState(TargetKind.SERIES, hasNextEpisode = true))
        assertTrue(HomeAction.PLAY_NEXT_EPISODE in a && HomeAction.MARK_SERIES_WATCHED in a && HomeAction.FAVORITE in a && HomeAction.WATCH_LATER in a)
        assertFalse(HomeAction.PLAY_NEXT_EPISODE in actionsFor(TargetState(TargetKind.SERIES)))
        assertTrue(HomeAction.MARK_SERIES_UNWATCHED in actionsFor(TargetState(TargetKind.SERIES, seriesWatched = true)))
    }
    @Test fun episodeListMenuHasOnlyEpisodeActions() {
        val a = actionsFor(TargetState(TargetKind.EPISODE, fromEpisodeList = true, hasResumePoint = true))
        assertEquals(HomeAction.RESUME, a.first()); assertTrue(HomeAction.START_OVER in a && HomeAction.MARK_WATCHED in a && HomeAction.INFO in a)
        assertFalse(HomeAction.FAVORITE in a || HomeAction.WATCH_LATER in a || HomeAction.DETAILS in a)
    }
    @Test fun movieMenuKeepsFavoriteAndWatchLater() { val a = actionsFor(TargetState(TargetKind.MOVIE)); assertTrue(HomeAction.FAVORITE in a && HomeAction.WATCH_LATER in a && HomeAction.DETAILS in a) }
}
