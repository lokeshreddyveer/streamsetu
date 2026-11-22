package app.streamsetu.tv

import org.junit.Assert.*
import org.junit.Test
import java.io.File

/** A link opened from a web page or another app may start a title the person could open by hand, and nothing else: it cannot change a setting. */
class DeepLinkSafetyTests {
    private val src = listOf("src/main/kotlin", "app/src/main/kotlin").map { File(it) }.first { it.exists() }.resolve("app/streamsetu/tv/MainActivity.kt").readText()
    private val handler = src.substring(src.indexOf("private fun handle("), src.indexOf("override fun onStop()"))

    @Test fun aLinkCannotChangeThePlayerEngineOrAnySetting() {
        assertFalse("engine parameter is read", Regex("""getQueryParameter\("engine"\)""").containsMatchIn(handler))
        assertTrue("the link handler writes no setting", Regex("""\.settings\.set\w+|\.ui\.set\w+|credentials\.save|setEngine""").findAll(handler).none())
    }

    @Test fun everyParameterTheHandlerReadsIsOneOfTheKnownSelectors() {
        val read = Regex("""getQueryParameter\(\s*"(\w+)"\s*\)""").findAll(handler).map { it.groupValues[1] }.toSet()
        assertTrue("unexpected parameters: ${read - setOf("id", "q", "kind")}", (read - setOf("id", "q", "kind")).isEmpty())
    }

    @Test fun aLinkByIdIsCheckedAsStrictlyAsAByNameLink() {
        assertTrue(handler.contains("c.mayPlay(item) && c.linkAllowed(item)"))
    }
}
