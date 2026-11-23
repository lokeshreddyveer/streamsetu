package app.streamsetu.core.data.smartmix

import app.streamsetu.core.data.repo.Similarity.Item
import org.junit.Assert.*
import org.junit.Test

class HomeBecauseTest {
    private fun item(id: String, title: String, year: Int? = 2020) = Item(id, title, year, null, null, "f")
    private val seed = item("s", "Heat Wave Rising", 2019)

    @Test fun threeTitlesOfTheSeedsFranchiseNameTheRowAndLeadIt() {
        val row = listOf(item("a", "Other Film"), item("b", "Heat Wave Two", 2021), item("c", "Heat Wave Three", 2022), item("d", "Heat Wave Four", 2023), item("e", "Something Else"))
        val link = HomeBecause.choose(listOf(seed), row)!!
        assertEquals("Heat Wave Rising", link.seedTitle)
        assertEquals(setOf("b", "c", "d"), link.linkedIds.toSet())
        assertEquals("Because You Watched Heat Wave Rising", HomeBecause.title(link))
        assertEquals(link.linkedIds.toSet(), HomeBecause.lead(listOf("a", "b", "c", "d", "e"), link).take(3).toSet())
    }

    @Test fun twoLinkedTitlesAreNotEnoughAndTheRowIsPickedForYou() {
        val row = listOf(item("a", "Other Film"), item("b", "Heat Wave Two", 2021), item("c", "Heat Wave Three", 2022), item("e", "Something Else"))
        assertNull(HomeBecause.choose(listOf(seed), row))
        assertEquals("Picked for You", HomeBecause.title(null))
        assertEquals(listOf("a", "b"), HomeBecause.lead(listOf("a", "b"), null))
    }

    @Test fun sameFolderOrYearAloneIsNoLink() {
        val row = (1..6).map { item("x$it", "Unrelated Name $it", 2019) }
        assertNull(HomeBecause.choose(listOf(seed), row))
    }

    @Test fun theNewestSeedWithEnoughLinksWinsATieAndTheSeedItselfIsNeverLinked() {
        val seed2 = item("s2", "Moon Harbor", 2018)
        val row = listOf(item("s", "Heat Wave Rising"), item("b", "Heat Wave Two"), item("c", "Heat Wave Three"), item("d", "Heat Wave Four"), item("m1", "Moon Harbor Two"), item("m2", "Moon Harbor Three"), item("m3", "Moon Harbor Four"))
        val link = HomeBecause.choose(listOf(seed, seed2), row)!!
        assertEquals("Heat Wave Rising", link.seedTitle)
        assertFalse("s" in link.linkedIds)
    }
}
