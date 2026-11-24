package app.streamsetu.tv

import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import app.streamsetu.core.data.repo.ArtworkMatchEngine
import app.streamsetu.core.data.repo.TmdbAuth
import app.streamsetu.tv.ui.screens.settings.InfoRow
import app.streamsetu.tv.ui.screens.settings.ToggleRow
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File

/** The pieces of the artwork work that are checked from the source and from the files: the Settings wording, one folder header everywhere, and that no token can be found in what git sees. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class, qualifiers = "w1920dp-h1080dp-xhdpi")
class ArtworkSourceAndSecretTests {
    @get:Rule val rule = createComposeRule()
    @get:Rule val patient = app.streamsetu.tv.ui.PatientIdle()
    @get:Rule val tmp = TemporaryFolder()

    private fun main(path: String) = File("src/main/kotlin/app/streamsetu/tv/$path").readText()
    private fun allMain() = File("src/main/kotlin").walkTopDown().filter { it.isFile && it.extension == "kt" }.toList()

    @Test fun theSwitchAndTheProgressLineAreReadableAndTheSwitchWorks() {
        var on = true
        rule.setContent {
            androidx.compose.runtime.CompositionLocalProvider {
                androidx.compose.foundation.layout.Column {
                    ToggleRow("Match artwork in the background", "Finds missing pictures by itself.", on) { on = it }
                    InfoRow("Artwork matching", "", ArtworkMatchEngine.Progress(1204, 3218, 61, ArtworkMatchEngine.State.RUNNING).line(locale = java.util.Locale.US))
                }
            }
        }
        rule.onNodeWithText("Match artwork in the background").assertExists()
        rule.onNodeWithText("Matching artwork: 1,204 of 3,218 done · 61 not found").assertExists()
        rule.onNodeWithText("Match artwork in the background").performClick(); rule.waitForIdle()
        assertFalse(on)
    }

    @Test fun settingsHaveTheNewRowsAndNoBatchWording() {
        val s = main("ui/screens/settings/SettingsScreen2.kt")
        for (label in listOf("Match artwork in the background", "\"Match now\"", "Test key", "Remove key", "Key in use", "Use mobile data", "Your own TMDB key (optional)")) assertTrue("missing $label", label in s)
        assertTrue("The built-in key is not working; add your own free key to keep artwork" in File("../data/src/main/kotlin/app/streamsetu/core/data/repo/ArtworkMatchEngine.kt").readText())
        for (f in allMain()) { val t = f.readText(); assertFalse("${f.name} still speaks of batches", "run it again" in t || "more are waiting" in t || "Fetch missing artwork" in t || "up to 150 titles" in t) }
        assertFalse("no key is built in" in allMain().joinToString("") { it.readText() }.lowercase() || "only with your own" in allMain().joinToString("") { it.readText() }.lowercase())
    }

    @Test fun everyFolderHeaderGoesThroughTheSharedComponentIncludingLiveTv() {
        // Movies, Series and Live TV, on a television and on a phone, draw their folder rows with the two shared row composables whose headers carry the quiet count: nothing else formats a count.
        assertTrue("TvFolderRows(" in main("ui/screens/section/SectionScreen.kt")); assertTrue("TvFolderRows(" in main("ui/screens/live/LiveScreen.kt"))
        val browse = main("ui/phone/PhoneBrowse.kt"); assertEquals("movies/series and live both use PhoneFolderRows", 2, Regex("PhoneFolderRows\\(").findAll(browse).count())
        assertTrue("TvFolderHeader(row" in main("ui/screens/folders/FolderRowsScreens.kt")); assertTrue("PhoneFolderHeader(row" in main("ui/phone/PhoneFolderRows.kt"))
        val formatters = allMain().filter { "\"(%,d)\".format" in it.readText() }.map { it.name }.sorted()
        assertEquals(listOf("FolderRowsScreens.kt", "PhoneFolderRows.kt"), formatters)
        // Live TV tiles: no folder name under them (only the channel name and what is on), and a designed placeholder when a channel has no logo.
        val tile = main("ui/screens/folders/FolderRowsScreens.kt").substringAfter("fun ChannelTile").substringBefore("\n}\n")
        assertFalse("folder" in tile.lowercase()); assertTrue("ChannelLogo(" in tile)
        assertTrue(main("ui/components/Basics.kt").substringAfter("fun ChannelLogo").substringBefore("\n}\n").contains("channelInitials(name)"))
        // Quality words in folder names stay in capitals.
        assertTrue("\"fhd\"" in File("../data/src/main/kotlin/app/streamsetu/core/data/repo/smartmix/FolderRowsPlan.kt").readText())
    }

    @Test fun aBuildWithOrWithoutTheTokenWorksAndTheTokenIsNotInBuildConfigOrResources() {
        val t = BuiltInTmdb.token()
        assertTrue("a build without a token returns nothing; one with it returns something shaped like a token", t == null || (t.startsWith("eyJ") && t.count { it == '.' } == 2))
        val auth = TmdbAuth({ null }, { BuiltInTmdb.token() })
        assertEquals(t != null, auth.available)
        assertEquals(if (t != null) TmdbAuth.Source.BUILT_IN else null, auth.source)
        if (t != null) {
            // the token is not written in clear in any source file, nor in generated BuildConfig or resources
            val hits = File("build").walkTopDown().filter { it.isFile && (it.name == "BuildConfig.java" || it.extension == "xml" || it.extension == "json") }.filter { f -> runCatching { f.readText().contains(t.takeLast(24)) }.getOrDefault(false) }.map { it.name }.toList()
            assertTrue("token material in $hits", hits.isEmpty())
            val gen = File("build/generated/streamsetu-tmdb").walkTopDown().filter { it.isFile }.joinToString("") { it.readText() }
            assertFalse("the generated source holds scrambled numbers only", gen.contains(t.take(20)) || gen.contains(t.takeLast(20)))
        }
    }

    @Test fun theSecretScanPassesHereAndFailsWithoutPrintingATokenThatIsPresent() {
        val script = File("../scripts/check-no-secrets.sh").takeIf { it.isFile } ?: return
        fun run(dir: File, env: Map<String, String>): Pair<Int, String> {
            val pb = ProcessBuilder("bash", File(dir, "scripts/check-no-secrets.sh").path).directory(dir).redirectErrorStream(true)
            pb.environment().remove("STREAMSETU_TMDB_TOKEN"); pb.environment().remove("TMDB_TOKEN_FILE"); pb.environment().putAll(env)
            val p = pb.start(); val out = p.inputStream.bufferedReader().readText(); return p.waitFor() to out
        }
        val repo = tmp.newFolder("repo"); File(repo, "scripts").mkdirs(); script.copyTo(File(repo, "scripts/check-no-secrets.sh"))
        ProcessBuilder("git", "init", "-q").directory(repo).start().waitFor()
        File(repo, "clean.txt").writeText("nothing here")
        assertEquals(0, run(repo, emptyMap()).first)
        val fake = listOf("eyJfakeheaderfakeheader1", "fakepayloadfakepayload22", "fakesignaturefakesignature33").joinToString(".")          // put together here so the source holds no token-shaped text
        File(repo, "leak.txt").writeText("key=$fake")
        val (code, out) = run(repo, mapOf("STREAMSETU_TMDB_TOKEN" to fake))
        assertEquals(1, code); assertTrue("FAIL" in out); assertFalse("the token must never be printed", out.contains("fakepayload"))
        // an APK-like zip holding it in a dex-like file
        File(repo, "leak.txt").delete()
        val apk = File(repo, "t.apk"); java.util.zip.ZipOutputStream(apk.outputStream()).use { z -> z.putNextEntry(java.util.zip.ZipEntry("classes.dex")); z.write(("dex\u0000$fake\u0000end").toByteArray()); z.closeEntry() }
        val r2 = ProcessBuilder("bash", File(repo, "scripts/check-no-secrets.sh").path, apk.path).directory(repo).redirectErrorStream(true).also { it.environment()["STREAMSETU_TMDB_TOKEN"] = fake }.start()
        val o2 = r2.inputStream.bufferedReader().readText(); assertEquals(1, r2.waitFor()); assertFalse(o2.contains("fakepayload"))
    }
}
