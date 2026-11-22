package app.streamsetu.core.data.repo.smartmix

import app.streamsetu.core.model.Folder
import app.streamsetu.core.model.FolderPref
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class FolderRowsPlanTests {
    private fun f(id: String, name: String = id, pref: FolderPref = FolderPref(), n: Int = 10) = Folder(id, "s", name, n, pref)

    @Test fun namesAreCleanedAndTheLanguageTagIsKept() {
        assertEquals("Action Movies · EN", FolderNaming.clean("EN | ACTION MOVIES"))
        assertEquals("Kids", FolderNaming.clean("★★ KIDS ★★"))
        assertEquals("Drama", FolderNaming.clean("Drama (1,204)"))
        assertEquals("General · English", FolderNaming.clean("General | English"))
        assertEquals("Comedy", FolderNaming.clean("Comedy"))
        assertEquals("★★", FolderNaming.clean("★★"))
        assertEquals("4K Movies", FolderNaming.clean("4K MOVIES"))
        assertEquals("English · 4K", FolderNaming.clean("English | 4k"))
        assertEquals("Movies FHD", FolderNaming.clean("Movies Fhd"))
        assertEquals("Netflix HD", FolderNaming.clean("NETFLIX HD"))
        assertEquals("UHD HDR movies", FolderNaming.clean("Uhd hdr movies"))
    }

    @Test fun hiddenAreOutPinnedAndArrangedFirstThenRecentThenLanguage() {
        val list = listOf(f("a"), f("p", pref = FolderPref(pinned = true)), f("h", pref = FolderPref(hidden = true)), f("m", pref = FolderPref(sortIndex = 3)),
            f("hin", "HINDI MOVIES"), f("r1"), f("r2"), f("z"))
        val out = FolderRowsPlan.order(list, mapOf("r1" to 5L, "r2" to 9L), "hindi").map { it.id }
        assertEquals(listOf("p", "m", "r2", "r1", "hin", "a", "z"), out)
    }

    @Test fun lockedFoldersKeepTheirPlaceAndNothingIsDropped() {
        val list = listOf(f("a"), f("l", pref = FolderPref(locked = true)), f("b"))
        assertEquals(listOf("a", "l", "b"), FolderRowsPlan.order(list, emptyMap(), null).map { it.id })
    }

    @Test fun theOrderIsStable() {
        val list = (1..50).map { f("f$it") }
        assertEquals(FolderRowsPlan.order(list, mapOf("f9" to 1L), null), FolderRowsPlan.order(list, mapOf("f9" to 1L), null))
        assertTrue(FolderRowsPlan.order(list, emptyMap(), null).size == 50)
    }
}
