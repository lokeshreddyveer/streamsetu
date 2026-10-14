package app.streamsetu.core.data

import app.streamsetu.core.data.repo.FolderOrder
import app.streamsetu.core.data.repo.MoveTo
import org.junit.Assert.*
import org.junit.Test

class FolderOrderTests {
    private val ids = listOf("a", "b", "c", "d")
    @Test fun upMovesExactlyOnePlace() = assertEquals(listOf("a", "c", "b", "d"), FolderOrder.move(ids, "c", MoveTo.UP))
    @Test fun downMovesExactlyOnePlace() = assertEquals(listOf("a", "c", "b", "d"), FolderOrder.move(ids, "b", MoveTo.DOWN))
    @Test fun firstAndLastMoveToTheEnds() {
        assertEquals(listOf("c", "a", "b", "d"), FolderOrder.move(ids, "c", MoveTo.FIRST))
        assertEquals(listOf("a", "b", "d", "c"), FolderOrder.move(ids, "c", MoveTo.LAST))
    }
    @Test fun edgesCannotMoveFurther() {
        assertNull(FolderOrder.move(ids, "a", MoveTo.UP)); assertNull(FolderOrder.move(ids, "a", MoveTo.FIRST))
        assertNull(FolderOrder.move(ids, "d", MoveTo.DOWN)); assertNull(FolderOrder.move(ids, "d", MoveTo.LAST))
    }
    @Test fun otherFoldersKeepTheirRelativeOrder() {
        val r = FolderOrder.move(ids, "d", MoveTo.FIRST)!!
        assertEquals(listOf("a", "b", "c"), r.filter { it != "d" })
    }
    @Test fun anUnknownFolderIsIgnored() = assertNull(FolderOrder.move(ids, "z", MoveTo.UP))
    @Test fun canMoveReportsAvailability() { assertFalse(FolderOrder.canMove(ids, "a", MoveTo.UP)); assertTrue(FolderOrder.canMove(ids, "a", MoveTo.DOWN)) }
}
