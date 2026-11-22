package app.streamsetu.tv

import app.streamsetu.tv.ui.screens.folders.FolderRowsModel
import org.junit.Assert.assertEquals
import org.junit.Test

class FolderRowProgressTests {
    @Test fun theGuideOffsetMovesTheClockAndSoTheBar() {
        val start = 1_000_000_000_000L; val end = start + 60 * 60_000L
        val real = start + 30 * 60_000L                 // half way by the real clock
        assertEquals(0.5f, FolderRowsModel.progress(FolderRowsModel.guideNow(real, 0), start, end), 0.001f)
        // a guide that runs 30 minutes late (offset +30): the bar is at the start
        assertEquals(0f, FolderRowsModel.progress(FolderRowsModel.guideNow(real, 30), start, end), 0.001f)
        // a guide 15 minutes early (offset -15): three quarters through
        assertEquals(0.75f, FolderRowsModel.progress(FolderRowsModel.guideNow(real, -15), start, end), 0.001f)
        assertEquals(1f, FolderRowsModel.progress(end + 10, start, end), 0f)
    }
}
