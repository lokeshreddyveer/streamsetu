package app.streamsetu.tv.ui.settings

import app.streamsetu.tv.ui.screens.settings.Category
import app.streamsetu.tv.ui.screens.settings.Exposure
import app.streamsetu.tv.ui.screens.settings.SettingsRegistry
import org.junit.Assert.*
import org.junit.Test
import java.io.File

class SettingsRegistryTests {
    private val dir = listOf("src/main/kotlin", "app/src/main/kotlin").map { File(it) }.first { it.exists() }.resolve("app/streamsetu/tv/ui/screens/settings")
    private val row = Regex("""\b(ToggleRow|ChoiceRow|ActionRow|SettingRow)\(\s*"((?:[^"\\]|\\.)*)"""")

    @Test fun everyIdIsUniqueAndEveryTitleIsWritten() {
        val ids = SettingsRegistry.all.map { it.id }
        assertEquals(ids.size, ids.toSet().size); assertTrue(SettingsRegistry.all.all { it.title.isNotBlank() })
    }

    @Test fun everyPageHasAtLeastOneSettingExceptThoseThatAreOnlyInformation() {
        val empty = Category.entries.filter { c -> SettingsRegistry.all.none { it.category == c } }
        assertTrue("pages with no listed setting: $empty", empty.all { it in setOf(Category.CHANNELS, Category.LIBRARIES, Category.SEARCH) } || empty.isEmpty())
    }

    /** The coverage check: a control added to a page without being added to the list (run scripts/gen_settings_registry.py) fails here. */
    @Test fun everyControlOnEveryPageIsInTheRegistry() {
        val listed = SettingsRegistry.all.map { it.category to it.title }.toSet()
        val missing = ArrayList<String>()
        for (f in dir.listFiles { x -> x.extension == "kt" && x.name !in setOf("Controls.kt", "SettingsRegistryData.kt", "SettingsRegistry.kt") }.orEmpty()) {
            val text = f.readText()
            for (m in Regex("""^(?:private |internal )?fun (?:[\w.]+\.)?(\w+)\(""", RegexOption.MULTILINE).findAll(text)) {
                val category = SettingsRegistry.pageFunctions[m.groupValues[1]] ?: continue
                val next = Regex("""^(?:@Composable|fun |private fun |internal fun |/\*\*)""", RegexOption.MULTILINE).find(text, m.range.last + 1)?.range?.first ?: text.length
                row.findAll(text.substring(m.range.first, next)).map { it.groupValues[2] }.filter { '$' !in it && it.isNotEmpty() }.forEach { t -> if ((category to t) !in listed) missing += "${f.name}: $category / $t" }
            }
        }
        assertTrue("not in the registry (run scripts/gen_settings_registry.py): $missing", missing.isEmpty())
    }

    @Test fun essentialNeverListsAnAdvancedPageOrAnAdvancedSetting() {
        val e = SettingsRegistry.visible(false)
        assertTrue(e.none { it.category in SettingsRegistry.advancedCategories }); assertTrue(e.all { it.exposure == Exposure.ESSENTIAL })
        assertTrue(SettingsRegistry.visible(true).size == SettingsRegistry.all.size); assertTrue(e.size < SettingsRegistry.all.size)
    }

    @Test fun theTechnicalSettingsAreAdvancedAndTheEverydayOnesAreEssential() {
        fun exp(title: String) = SettingsRegistry.all.first { it.title == title }.exposure
        assertEquals(Exposure.ADVANCED, exp("Default engine")); assertEquals(Exposure.ESSENTIAL, exp("Theme"))
    }

    @Test fun searchFindsByTitleKeywordAndDescriptionAndBestMatchComesFirst() {
        val r = SettingsRegistry.search("theme", advanced = true)
        assertTrue(r.isNotEmpty()); assertEquals("Theme", r.first().title)
        assertTrue(SettingsRegistry.search("zzzzqq", true).isEmpty()); assertTrue(SettingsRegistry.search("a", true).isEmpty())
    }

    @Test fun essentialSearchNeverReturnsAnAdvancedSetting() {
        assertTrue(SettingsRegistry.search("engine", advanced = false).none { it.exposure == Exposure.ADVANCED })
        assertTrue(SettingsRegistry.search("engine", advanced = true).any { it.title == "Default engine" })
    }

    @Test fun theAssistantCatalogDescribesSettingsAndNeverHoldsAValueOrAPrivateSetting() {
        val text = SettingsRegistry.assistantCatalog(advanced = true)
        assertTrue(text.contains("Theme"))
        SettingsRegistry.all.filter { it.sensitive }.forEach { s -> assertFalse("${s.title} is private", text.contains(s.id)) }
        assertTrue(SettingsRegistry.all.any { it.sensitive })
    }
}

class SettingsSearchTests {
    @Test fun everyCuratedAliasBelongsToARealSetting() {
        val ids = SettingsRegistry.all.map { it.id }.toSet()
        val unknown = SettingsRegistry.aliases.keys.filter { it !in ids }
        assertTrue("aliases for settings that do not exist: $unknown", unknown.isEmpty())
    }

    private fun top(q: String, advanced: Boolean = true) = SettingsRegistry.search(q, advanced).map { it.title }

    @Test fun peopleFindSettingsByTheWordsTheyActuallyUse() {
        assertTrue(top("subtitle size").take(3).contains("Size"))
        assertTrue(top("dns").any { it.contains("DNS") })
        assertTrue(top("buffer").take(3).any { it.contains("buffer") })
        assertTrue(top("parental pin").take(3).any { it.contains("PIN") })
        assertTrue(top("clear cache").take(5).any { it.contains("cache") })
    }

    @Test fun everyResultNamesARealPageAndARowTheFocusCanFind() {
        SettingsRegistry.all.forEach { d -> assertTrue(d.title.isNotBlank()); assertEquals(d.title, d.focusTargetId); assertTrue(Category.entries.contains(d.category)) }
    }

    @Test fun searchIsFastEnoughToRunOnEveryKeystroke() {
        repeat(20) { SettingsRegistry.search("subtitle size", true) }
        val t = System.nanoTime(); repeat(100) { SettingsRegistry.search("subtitle size", true) }
        val ms = (System.nanoTime() - t) / 100 / 1_000_000.0
        assertTrue("one search took $ms ms", ms < 5.0)
    }

    @Test fun essentialSearchHidesTheAdvancedPagesUntilAskedFor() {
        assertTrue(SettingsRegistry.search("diagnostics", advanced = false).none { it.category in SettingsRegistry.advancedCategories })
        assertTrue(SettingsRegistry.search("clear the artwork cache", advanced = true).any { it.category == Category.STORAGE })
    }
}
