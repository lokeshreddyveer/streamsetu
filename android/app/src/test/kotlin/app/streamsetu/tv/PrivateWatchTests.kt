package app.streamsetu.tv

import app.streamsetu.tv.ui.screens.home.*
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PrivateWatchTests {
    @Test fun aPlayThatAsksIsAsAsked() {
        assertTrue(PrivateWatch.resolve(true, wasOn = false, somethingPlaying = false))
        assertFalse(PrivateWatch.resolve(false, wasOn = true, somethingPlaying = true))     // a fresh ordinary play is not private, even over a private one
    }

    @Test fun achannelChangeOrTheNextEpisodeCarriesOnPrivatelyOnlyWhileSomethingPrivatePlays() {
        assertTrue(PrivateWatch.resolve(null, wasOn = true, somethingPlaying = true))
        assertFalse(PrivateWatch.resolve(null, wasOn = true, somethingPlaying = false))     // it ended: whatever starts next is ordinary
        assertFalse(PrivateWatch.resolve(null, wasOn = false, somethingPlaying = true))
    }

    @Test fun everyKindOfCardOffersWatchPrivately() {
        for (k in TargetKind.entries) assertTrue(k.name, HomeAction.WATCH_PRIVATELY in actionsFor(TargetState(k)))
        assertTrue(HomeAction.WATCH_PRIVATELY in actionsFor(TargetState(TargetKind.EPISODE, fromEpisodeList = true)))
    }

    @Test fun theLockScreenTitleTellsNothing() = assertEquals("Private viewing", PrivateWatch.TITLE)
}
