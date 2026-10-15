package app.streamsetu.tv

import app.streamsetu.core.playback.PlayerTuning
import app.streamsetu.tv.ui.components.PlayerMenus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PlayerMenusTests {
    @Test fun timesAreReadInAnyOfTheThreeForms() {
        assertEquals(5_025_000L, PlayerMenus.parseTime("1:23:45"))
        assertEquals(5_025_000L, PlayerMenus.parseTime("83:45"))
        assertEquals(45_000L, PlayerMenus.parseTime("45"))
        assertEquals(5_025_000L, PlayerMenus.parseTime(" 1 : 23 : 45 "))
    }

    @Test fun notATimeIsRefused() {
        assertNull(PlayerMenus.parseTime(""))
        assertNull(PlayerMenus.parseTime("abc"))
        assertNull(PlayerMenus.parseTime("1:2:3:4"))
        assertNull(PlayerMenus.parseTime("-5"))
    }

    @Test fun clockShowsHoursOnlyWhenNeeded() {
        assertEquals("1:23:45", PlayerMenus.clock(5_025_000))
        assertEquals("3:05", PlayerMenus.clock(185_000))
        assertEquals("0:00", PlayerMenus.clock(0))
    }

    @Test fun tuningKnowsWhenPictureWasChanged() {
        assertFalse(PlayerTuning().picture)
        assertTrue(PlayerTuning(brightness = 5).picture)
        assertTrue(PlayerTuning(deinterlace = true).picture)
        assertFalse(PlayerTuning(boostPercent = 130, softwareDecoding = true).picture)       // sound and decoding are not the picture
    }
}
