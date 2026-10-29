package app.streamsetu.tv

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** The phone's Live TV grid reads the same paged view model as the TV (150 channels at a time), so it must ask for the next page; without it the phone stops at the first 150 channels. */
class PhoneLivePagingTest {
    private val root = generateSequence(File("").absoluteFile) { it.parentFile }.first { File(it, "settings.gradle.kts").exists() }
    private val phone = root.walkTopDown().first { it.name == "PhoneBrowse.kt" && "/src/main/" in it.path }.readText()

    private fun liveBody() = phone.substring(phone.indexOf("fun PhoneLive("))

    @Test fun theLiveGridAsksForTheNextPageNearItsEnd() {
        val b = liveBody()
        assertTrue("PhoneLive must call vm.loadMore()", "vm.loadMore()" in b)
        assertTrue("and only from a near-the-end check on the grid", "gridState.layoutInfo" in b && "n - 30" in b)
    }

    @Test fun aFailedPageCanBeRetriedAndALoadingPageIsShown() {
        val b = liveBody()
        assertTrue("vm.retryPage()" in b); assertTrue("vm.pageFailed" in b); assertTrue("vm.loadingMore" in b)
    }
}
