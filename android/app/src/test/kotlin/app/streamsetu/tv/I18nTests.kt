package app.streamsetu.tv

import app.streamsetu.tv.ui.i18n.I18n
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class I18nTests {
    private fun table(code: String) = JSONObject(File("src/main/assets/i18n/$code.json").readText())
    private fun keys(o: JSONObject) = o.keys().asSequence().toSet()

    @Test fun bothLanguagesCoverTheSameTexts() {
        val hi = table("hi"); val te = table("te")
        assertEquals(keys(hi.getJSONObject("strings")), keys(te.getJSONObject("strings")))
        assertEquals(keys(hi.getJSONObject("templates")), keys(te.getJSONObject("templates")))
        assertTrue(keys(hi.getJSONObject("strings")).size > 300)
    }

    @Test fun everyTranslationIsFilledAndKeepsItsPlaceholders() {
        for (code in listOf("hi", "te")) {
            val root = table(code)
            for (section in listOf("strings", "templates")) {
                val o = root.getJSONObject(section)
                for (k in keys(o)) {
                    val v = o.getString(k)
                    assertTrue("$code/$k is empty", v.isNotBlank())
                    assertEquals("$code/$k has a different number of {} than the English", k.split("{}").size, v.split("{}").size)
                }
            }
        }
    }

    @Test fun templatesMatchChangingText() {
        val re = I18n.templateRegex("Continue S{} E{}")
        val m = re.matchEntire("Continue S2 E10")!!
        assertEquals(listOf("2", "10"), m.groupValues.drop(1))
        assertEquals(null, re.matchEntire("Continue watching"))
        assertEquals("Season 3", I18n.tr("Season 3"))                    // no language loaded: text is left alone
    }
}
