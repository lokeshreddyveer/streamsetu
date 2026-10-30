package app.streamsetu.tv

import android.app.AlarmManager
import android.content.Context
import android.content.Intent
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.assertCountEquals
import androidx.test.core.app.ApplicationProvider
import app.streamsetu.core.data.repo.SearchTarget
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Tab
import app.streamsetu.tv.sports.SportsFeature
import app.streamsetu.tv.sports.personal.SportsRescheduleReceiver
import app.streamsetu.tv.sports.personal.SportsReminderReceiver
import app.streamsetu.tv.ui.components.Sidebar
import org.junit.After
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows
import org.robolectric.annotation.Config
import java.io.File

/**
 * Sports is unlinked from the app by one switch that is off by default: the code, tests, tables and data stay, and nothing in the app reaches them. These tests hold that: with the switch off
 * there is no way to Sports, no Sports search, no Sports service started, no Sports alarm or receiver work; and the rest of the app (the other tabs, Search, recordings, Multi-View) is as it was.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class, qualifiers = "w1920dp-h1080dp-xhdpi")
class SportsDisabledTests {
    @get:Rule val rule = createComposeRule()
    private val context: Context get() = ApplicationProvider.getApplicationContext()
    @After fun reset() { SportsFeature.forTest(null) }

    private fun main(path: String) = File("src/main/kotlin/app/streamsetu/tv/$path").readText()

    @Test fun theSwitchIsOffByDefaultInTheBuild() {
        SportsFeature.forTest(null)
        assertFalse(SportsFeature.enabled); assertFalse("the build constant is false unless -PsportsEnabled=true is passed", BuildConfig.SPORTS_ENABLED)
        val gradle = File("build.gradle.kts").readText()
        assertTrue(gradle.contains("(project.findProperty(\"sportsEnabled\") as String?) == \"true\""))
        SportsFeature.forTest(true); assertTrue(SportsFeature.enabled); SportsFeature.forTest(false); assertFalse(SportsFeature.enabled)
    }

    // ---- no navigation destination

    private val chosen = mutableStateListOf<Tab>()
    private fun showSidebar() = rule.setContent { Sidebar(Tab.HOME, onSelect = { chosen += it }, entry = FocusRequester(), expanded = true) }

    @Test fun theSidebarHasNoSportsEntryAndEveryOtherEntryIsStillThere() {
        SportsFeature.forTest(false); showSidebar()
        rule.onAllNodesWithTag("sidebar-SPORTS").assertCountEquals(0)
        for (t in listOf(Tab.HOME, Tab.LIVE, Tab.GUIDE, Tab.MOVIES, Tab.SERIES, Tab.SEARCH, Tab.LIBRARIES, Tab.SETTINGS)) rule.onAllNodesWithTag("sidebar-${t.name}").assertCountEquals(1)
    }

    @Test fun withTheSwitchOnTheEntryIsBackBetweenLiveTvAndTheGuide() {
        SportsFeature.forTest(true); showSidebar()
        rule.onAllNodesWithTag("sidebar-SPORTS").assertCountEquals(1)
    }

    @Test fun theNavigatorCannotReachSportsByAnyRoute() {
        SportsFeature.forTest(false)
        val nav = Navigator(); nav.tab = Tab.LIVE
        nav.go(Tab.SPORTS); assertEquals("a request for the Sports tab is ignored", Tab.LIVE, nav.tab)
        nav.openSports(SearchTarget.OpenSports("event", "k", "CRICKET", "n", "e")); assertEquals(Tab.LIVE, nav.tab); assertNull("nothing is remembered to open later", nav.pendingSportsTarget)
        nav.go(Tab.GUIDE); assertEquals("other tabs still work", Tab.GUIDE, nav.tab); nav.go(Tab.HOME); assertEquals(Tab.HOME, nav.tab)
        SportsFeature.forTest(true); nav.go(Tab.SPORTS); assertEquals(Tab.SPORTS, nav.tab)
    }

    // ---- no Sports search

    @Test fun globalSearchLooksUpNoSportsResultsWhenOff() {
        assertFalse(app.streamsetu.tv.ui.screens.search.sportsSearchActive(enabled = false, canOpen = true, allTypes = true, allTab = true))
        assertTrue(app.streamsetu.tv.ui.screens.search.sportsSearchActive(true, true, true, true))
        assertFalse("never from a section's own search", app.streamsetu.tv.ui.screens.search.sportsSearchActive(true, false, true, true))
        val search = main("ui/screens/search/SearchContent.kt")
        assertEquals("the Sports lookup is reached from one place, and that place is behind the switch", 1, Regex("c\\.sportsSearch\\.search\\(").findAll(search).count())
        assertTrue(search.contains("val sportsOn = sportsSearchActive(app.streamsetu.tv.sports.SportsFeature.enabled,"))
        assertTrue("the context flow is read only when the lookup is on", search.contains("if (sportsOn) c.sportsSearchSource.contextFlow else kotlinx.coroutines.flow.flowOf(\"\")"))
        assertTrue(search.contains("onSports = if (app.streamsetu.tv.sports.SportsFeature.enabled)"))
        assertTrue("the effect returns before the call when off", search.contains("if (!sportsOn || query.isBlank()) { sportsItems = emptyList(); return@LaunchedEffect }"))
    }

    // ---- nothing in Sports is started

    private val sportsMembers = Regex("""(container|\bc)\.(sportsService|sportsInputs|sportsPlayback|sportsReminders|sportsRecordings|sportsFollows|sportsSearch|sportsSearchSource|sportsMultiview)\b|\bsports(Service|Inputs|Playback|Reminders|Recordings|Follows|Search|SearchSource)\.""")

    @Test fun everyPlaceOutsideSportsThatWouldStartASportsServiceIsBehindTheSwitch() {
        // The one allowed exception, said plainly: the ordinary Multi-View and the player's "Add to Multiview" share one tile session with Sports (see MultiViewScreen). The session itself holds no Sports event, follow, reminder or recording.
        val sharedMultiview = setOf("ui/screens/MultiViewScreen.kt")
        val skipDirs = listOf("sports/", "ui/screens/sports/")
        val root = File("src/main/kotlin/app/streamsetu/tv"); val offenders = ArrayList<String>()
        root.walkTopDown().filter { it.extension == "kt" }.forEach { f ->
            val rel = f.relativeTo(root).path
            if (skipDirs.any { rel.startsWith(it) } || rel in sharedMultiview || rel == "StreamSetuApp.kt" && false) return@forEach
            f.readLines().forEachIndexed { i, line ->
                val code = line.substringBefore("//").trim()
                if (code.startsWith("*") || code.startsWith("/*") || code.startsWith("import ")) return@forEachIndexed
                if (!sportsMembers.containsMatchIn(code)) return@forEachIndexed
                if (rel == "StreamSetuApp.kt" && code.contains(" by lazy")) return@forEachIndexed                       // the declaration of a lazy member starts nothing
                if (code.contains("SportsFeature.enabled") || code.contains("sportsOn")) return@forEachIndexed                  // sportsOn is derived from the switch (sportsSearchActive)
                if (rel == "StreamSetuApp.kt" && code.contains("sportsPlayback.rankInput(")) return@forEachIndexed        // inside the lazy Multi-View builder, called only when an event is ranked
                if (rel == "ui/screens/search/SearchContent.kt" && code.contains("c.sportsSearch.search(")) return@forEachIndexed   // the one call, after the effect returns early when the lookup is off (asserted in globalSearchLooksUpNoSportsResultsWhenOff)
                if (rel == "ui/components/SportsReminderBanner.kt") return@forEachIndexed                                 // the banner itself; it is composed only behind the switch (checked in nothingStartsSportsAtLaunchOrOnADeepLink)
                offenders += "$rel:${i + 1}"
            }
        }
        // PlayerScreen's feed panel and its "Add to Multiview" are reachable only through state that cannot exist with Sports off (no Sports stream has an origin), checked below.
        val allowed = setOf("ui/screens/PlayerScreen.kt")
        val real = offenders.filter { it.substringBefore(':') !in allowed }
        assertTrue("unguarded Sports starts: $real", real.isEmpty())
        val player = main("ui/screens/PlayerScreen.kt")
        assertTrue("the player reads Sports playback state only when the switch is on", player.contains("val sports = if (app.streamsetu.tv.sports.SportsFeature.enabled) c.sportsPlayback.state"))
        assertTrue("so the Feeds pill and Add to Multiview, which need a Sports origin, never show", player.contains("val feedsAvailable = live && item is ChannelPlayable && sports.canSwitch()"))
    }

    @Test fun nothingStartsSportsAtLaunchOrOnADeepLink() {
        val activity = main("MainActivity.kt"); val app = main("StreamSetuApp.kt")
        assertTrue(activity.contains("if (app.streamsetu.tv.sports.SportsFeature.enabled) container.sportsReminders.start()"))
        assertTrue(app.contains("if (app.streamsetu.tv.sports.SportsFeature.enabled) container.sportsRecordings.start(container.appScope)"))
        assertTrue(app.contains("if (app.streamsetu.tv.sports.SportsFeature.enabled) sportsReminders.securityChanged()"))
        assertTrue("a Sports link is read and dropped when off", activity.contains("openIdFrom(intent)?.let { id -> if (app.streamsetu.tv.sports.SportsFeature.enabled) { nav.pendingSportsReminder = id;"))
        assertTrue(activity.contains("Tab.SPORTS -> if (app.streamsetu.tv.sports.SportsFeature.enabled)"))
        assertTrue(activity.contains("is Overlay.SportsMultiview -> if (app.streamsetu.tv.sports.SportsFeature.enabled)"))
        assertTrue(activity.contains("if (nav.base == Base.Shell && app.streamsetu.tv.sports.SportsFeature.enabled) app.streamsetu.tv.ui.components.SportsReminderBanner"))
        assertTrue("the guide is read for Sports only from the Sports screen, search and recording code that the switch guards", !app.contains("sportsService.events(") && !activity.contains("sportsService"))
    }

    // ---- no Sports alarm, receiver or recording work

    private val alarms get() = Shadows.shadowOf(context.getSystemService(Context.ALARM_SERVICE) as AlarmManager).scheduledAlarms

    @Test fun theSportsReceiversDoNothingWhenOff() {
        SportsFeature.forTest(false); alarms.clear()
        val alarm = Intent(context, SportsReminderReceiver::class.java).setData(android.net.Uri.parse("streamsetu-sports-alarm://some-id"))
        SportsReminderReceiver().onReceive(context, alarm)
        for (a in listOf(Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED, Intent.ACTION_TIMEZONE_CHANGED)) SportsRescheduleReceiver().onReceive(context, Intent(a))
        assertTrue("no alarm was set", alarms.isEmpty())
    }

    @Test fun theSportsReceiversAreDisabledComponentsInTheManifestAndGuardedFirstInCode() {
        val m = File("src/main/AndroidManifest.xml").readText()
        assertEquals(2, Regex("android:enabled=\"\\$\\{sportsReceiversEnabled\\}\"").findAll(m).count())
        assertTrue(m.contains("SportsReminderReceiver\" android:exported=\"false\" android:enabled=") && m.contains("SportsRescheduleReceiver\" android:exported=\"false\" android:enabled="))
        val src = main("sports/personal/RealReminderDeps.kt")
        assertEquals(2, Regex("if \\(!app\\.streamsetu\\.tv\\.sports\\.SportsFeature\\.enabled\\) return").findAll(src).count())
        val gradle = File("build.gradle.kts").readText(); assertTrue(gradle.contains("manifestPlaceholders[\"sportsReceiversEnabled\"] = sportsOn.toString()"))
    }

    @Test fun theSharedRecordingAndGuideCodeHasNoSwitchAndIsUnchanged() {
        // Recordings, the Guide, Live TV, Home and Search belong to the app, not to Sports: they take no part in the switch.
        for (f in listOf("record/ScheduledRecordings.kt", "ui/screens/guide/GuideScreen.kt", "ui/screens/live/LiveScreen.kt", "ui/screens/home/HomeScreen.kt")) assertFalse("$f must not read the Sports switch", main(f).contains("SportsFeature"))
        assertTrue(main("ui/screens/search/SearchContent.kt").contains("c.globalSearch.search(query, tab,"))
    }
}
