package app.streamsetu.tv.ui

import app.streamsetu.core.sync.SyncProgress
import app.streamsetu.tv.LibraryFill
import app.streamsetu.tv.nav.FolderNav
import app.streamsetu.tv.ui.components.channelInitials
import app.streamsetu.tv.ui.components.fillingParts
import app.streamsetu.tv.ui.theme.Tokens
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

/** Live TV opens with its group list like Movies and Series; the library-filling signal; the channel badge; the safe margins. */
class LiveLayoutAndFillTests {
    @Test fun theGroupListIsOpenWhenLiveTvOpensAndBackWalksOutward() {
        val nav = FolderNav(startOpen = true)
        assertTrue(nav.open)
        nav.hide(); assertFalse(nav.open)                       // Right or OK: the shelves take the remote
        assertEquals(FolderNav.Next.NOTHING, nav.back()); assertTrue(nav.open)          // Back from the shelves shows the groups
        assertEquals(FolderNav.Next.MAIN_SIDEBAR, nav.back()); assertFalse(nav.open)    // Back from the groups reaches the main sidebar
    }
    @Test fun fillingIsOnWhileAReadOrTheIdentityFillRuns() = runBlocking {
        val f = LibraryFill()
        assertFalse(f.filling.first())
        f.syncStarted(); assertTrue(f.filling.first()); f.syncStarted(); f.syncEnded(); assertTrue(f.filling.first())
        f.syncEnded(); assertFalse(f.filling.first())
        f.identityRunning(true); assertTrue(f.fillingNow); f.identityRunning(false); assertFalse(f.fillingNow)
    }
    @Test fun progressIsForgottenWhenTheLastReadEnds() {
        val f = LibraryFill()
        f.syncStarted(); f.report(SyncProgress(SyncProgress.Stage.READING_MOVIES, 5, 0)); assertNotNull(f.progress.value)
        f.syncEnded(); assertNull(f.progress.value)
        f.syncEnded(); assertFalse(f.fillingNow)          // never below zero
    }
    @Test fun progressTextIsSplitForTranslation() {
        assertEquals("Saving movies" to "12,000 of 66,000", fillingParts(SyncProgress(SyncProgress.Stage.SAVING_MOVIES, 12000, 66000)))
        assertEquals("Reading movies" to "24,000", fillingParts(SyncProgress(SyncProgress.Stage.READING_MOVIES, 24000, 0)))
        assertEquals("Signing in" to null, fillingParts(SyncProgress(SyncProgress.Stage.SIGNING_IN, 0, 0)))
    }
    @Test fun channelBadgeSkipsTheProviderPrefix() {
        assertEquals("NJ", channelInitials("BG: Nick Junior")); assertEquals("FM", channelInitials("FR| FRANCE MARTINIQUE"))
        assertEquals("PE", channelInitials("PPV EVENT 01")); assertEquals("ES", channelInitials("ESPN")); assertEquals("?", channelInitials("|||"))
    }
    @Test fun marginsAreFivePercent() {
        assertEquals(48f, Tokens.safeHorizontalFor(960f), 0.01f); assertEquals(27f, Tokens.safeVerticalFor(540f), 0.01f)
        assertEquals(64f, Tokens.safeHorizontalFor(1920f), 0.01f)          // never wider than 64 dp
    }
    @Test fun secondaryTextIsAtLeast14sp() { assertTrue(Tokens.small.value >= 14f); assertTrue(Tokens.body.value >= 16f); assertTrue(Tokens.row.value >= 16f) }
}
