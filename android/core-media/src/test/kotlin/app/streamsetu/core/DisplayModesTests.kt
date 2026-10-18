package app.streamsetu.core

import app.streamsetu.core.playback.DisplayMode
import app.streamsetu.core.playback.DisplayModes
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DisplayModesTests {
    private val hz60 = DisplayMode(1, 3840, 2160, 60f)
    private val modes = listOf(hz60, DisplayMode(2, 3840, 2160, 30f), DisplayMode(3, 3840, 2160, 24f), DisplayMode(4, 3840, 2160, 50f), DisplayMode(5, 1920, 1080, 25f), DisplayMode(6, 3840, 2160, 23.976f))

    @Test fun aFilmAt24SwitchesTheScreenTo24() = assertEquals(3, DisplayModes.best(modes, hz60, 24f)?.id)
    @Test fun aFilmAt23976UsesTheMatchingMode() = assertEquals(6, DisplayModes.best(modes, hz60, 23.976f)?.id)
    @Test fun aVideoAt25UsesFiftyWhenThereIsNo25AtThisSize() = assertEquals(4, DisplayModes.best(modes, hz60, 25f)?.id)
    @Test fun a30FpsVideoNeedsNoSwitchAt60() = assertNull(DisplayModes.best(modes, hz60, 30f))
    @Test fun theSizeOfTheScreenNeverChanges() = assertNull(DisplayModes.best(listOf(hz60, DisplayMode(5, 1920, 1080, 25f)), hz60, 25f))
    @Test fun anUnknownFrameRateIsLeftAlone() = assertNull(DisplayModes.best(modes, hz60, 0f))
}
