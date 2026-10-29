package app.streamsetu.tv.sports.discovery

import app.streamsetu.core.model.Channel
import app.streamsetu.core.model.EpgProgram
import app.streamsetu.core.sports.Sport
import app.streamsetu.core.sports.SportsEvent
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.nav.Tab
import app.streamsetu.tv.sports.FakePlaybackDeps
import app.streamsetu.tv.sports.personal.Follow
import app.streamsetu.tv.sports.personal.FollowKind
import app.streamsetu.tv.sports.personal.FollowSet
import app.streamsetu.tv.sports.personal.SportsKeys
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.io.File

class GuideLinkAndHintTests {
    private val now = D.NOW; private val h = D.H

    private fun deps(vararg ids: String): FakePlaybackDeps = FakePlaybackDeps().also { d -> ids.forEach { d.channels[it] = Channel(it, "A", "cat", "Channel $it", null, null, "ref", null) } }
    private fun event(vararg channels: String) = D.event("e", now + h, listOf("India", "Nepal"), channels = channels.toList())
    private fun prog(ch: String, start: Long, mins: Long = 120) = EpgProgram(ch, start, start + mins * 60_000L, "p", null)
    private fun <T> run(b: suspend () -> T): T = runBlocking { b() }

    // ---- Open Guide: the target

    @Test fun theTargetIsTheAuthorizedChannelAndTheProgrammesTimeAsTheGuideShowsIt() {
        val d = deps("c1"); val e = event("c1")
        val t = run { GuideLink.target(d, e, 5 * D.MIN, emptyList()) }!!
        assertEquals("c1", t.channelId); assertEquals("the guide time offset is applied", e.feeds.single().programmeStartMs + 5 * D.MIN, t.startMs)
    }

    @Test fun theBestRankedAuthorizedFeedIsChosenAndAnUnauthorizedOneNeverIs() {
        val d = deps("c1", "c2", "c3"); val e = event("c1", "c2", "c3")
        assertEquals("c2", run { GuideLink.target(d, e, 0, listOf("c2", "c1", "c3")) }!!.channelId)
        d.hiddenChannels.add("c2"); assertEquals("the next best, never the hidden one", "c1", run { GuideLink.target(d, e, 0, listOf("c2", "c1", "c3")) }!!.channelId)
    }

    @Test fun aRestrictedChannelCannotBeDeepLinkedWhateverTheRestriction() {
        val e = event("c1")
        fun blocked(change: (FakePlaybackDeps) -> Unit): Boolean { val d = deps("c1"); change(d); return run { GuideLink.target(d, e, 0, emptyList()) } == null }
        assertTrue("hidden", blocked { it.hiddenChannels.add("c1") })
        assertTrue("folder relocked", blocked { it.lockedCategories.add("cat") })
        assertTrue("adult or kids rule", blocked { it.adultFilter = true; it.adultCategories.add("cat") })
        assertTrue("playlist off", blocked { it.disabledSources.add("A") })
        assertTrue("another library", blocked { it.active = setOf("Z") })
        assertTrue("channel gone", blocked { it.channels.clear() })
        assertNotNull("and with no restriction it is reachable", run { GuideLink.target(deps("c1"), e, 0, emptyList()) })
    }

    // ---- Open Guide: where the Guide lands

    private val t0 = now + h
    @Test fun theGuideLandsOnTheProgrammeWhenItIsStillThere() {
        val rows = listOf("c0" to listOf(prog("c0", t0)), "c1" to listOf(prog("c1", t0 - 3 * h), prog("c1", t0)))
        assertEquals(GuideLanding.Programme("c1", t0), GuideLink.land(rows, GuideTarget("c1", t0)))
    }

    @Test fun ifTheGuideChangedItLandsOnTheChannelAtWhatIsOnAirThen() {
        val moved = listOf("c1" to listOf(prog("c1", t0 - 20 * D.MIN, 150)))
        assertEquals("the start moved by a few minutes: the programme on air at that time", GuideLanding.Channel("c1", t0 - 20 * D.MIN), GuideLink.land(moved, GuideTarget("c1", t0)))
        val later = listOf("c1" to listOf(prog("c1", t0 - 5 * h), prog("c1", t0 + 4 * h)))
        assertEquals("a gap: the next programme", GuideLanding.Channel("c1", t0 + 4 * h), GuideLink.land(later, GuideTarget("c1", t0)))
    }

    @Test fun ifTheProgrammeIsRemovedItFallsBackToTheChannelRowAndNeverToAnotherChannel() {
        val gone = listOf("c0" to listOf(prog("c0", t0)), "c1" to emptyList())
        assertEquals(GuideLanding.Channel("c1", null), GuideLink.land(gone, GuideTarget("c1", t0)))
        assertEquals("the channel is not listed: asked for once by its exact id", GuideLanding.NotListed, GuideLink.land(gone.filter { it.first == "c0" }, GuideTarget("c1", t0)))
    }

    // ---- identity never widens from the channel id to its name

    private fun ch(id: String, source: String, name: String = "Sky Sports 1") = Channel(id, source, "cat", name, null, null, "ref", "g")

    @Test fun twoIdenticallyNamedChannelsOfDifferentPlaylistsAreNeverConfused() {
        val a = ch("A:1", "A"); val b = ch("B:1", "B"); val c = ch("A:2", "A", "Sky Sports 1 HD")
        val all = listOf(a, b, c)
        assertEquals(listOf(b), GuideLink.onlyId(all, "B:1") { it.id }); assertEquals(listOf(a), GuideLink.onlyId(all, "A:1") { it.id })
        assertTrue("an id that is not there finds nothing, however many channels share a name", GuideLink.onlyId(all, "C:1") { it.id }.isEmpty())
        // the target carries the id of the authorized feed, so the playlist that was authorized is the one that is selected
        val d = deps().also { it.channels["A:1"] = a; it.channels["B:1"] = b; it.active = setOf("A", "B"); it.disabledSources.add("A") }
        val base = D.event("e", now + h, listOf("India", "Nepal"), channels = listOf("x"))
        val e = base.copy(feeds = listOf(base.feeds[0].copy(channelId = "A:1", sourceId = "A"), base.feeds[0].copy(channelId = "B:1", sourceId = "B")))
        assertEquals("the authorized one, not the same-named disabled playlist's", "B:1", run { GuideLink.target(d, e, 0, listOf("A:1", "B:1")) }!!.channelId)
    }

    @Test fun landingNeverFallsBackToAnotherRowWithTheSameName() {
        val rows = listOf("A:1" to listOf(prog("A:1", t0)))                        // a same-named channel of another playlist is listed; the target is B:1
        assertEquals(GuideLanding.NotListed, GuideLink.land(rows, GuideTarget("B:1", t0)))
    }

    @Test fun theGuideNeverFiltersByNameForALink() {
        val guide = File("src/main/kotlin/app/streamsetu/tv/ui/screens/guide/GuideScreen.kt").readText()
        assertFalse("no name-based narrowing", guide.contains("c.catalog.channel(t.channelId)?.name") || guide.contains("query.value = n"))
        assertTrue(guide.contains("onlyId.value = t.channelId") && guide.contains("This channel is no longer available in the Guide."))
    }

    @Test fun anOldProgrammeOnlyFallsBackToTheChannelsFirst() {
        val onlyPast = listOf("c1" to listOf(prog("c1", t0 - 9 * h, 60)))
        assertEquals(GuideLanding.Channel("c1", t0 - 9 * h), GuideLink.land(onlyPast, GuideTarget("c1", t0)))
    }

    @Test fun theNavigatorCarriesTheTargetToTheGuideAndNothingElse() {
        val nav = Navigator(); nav.openGuideAt(GuideTarget("c1", t0))
        assertEquals(Tab.GUIDE, nav.tab); assertEquals(GuideTarget("c1", t0), nav.pendingGuideTarget)
        val fields = GuideTarget::class.java.declaredFields.filter { !it.name.startsWith("$") }.map { it.name }.toSet()
        assertEquals("an id and a time: no name, address or title", setOf("channelId", "startMs"), fields)
    }

    @Test fun theGuideTakesTheTargetOnceAndTheEventScreenOpensItOnlyThroughTheCheckedPath() {
        val screen = File("src/main/kotlin/app/streamsetu/tv/ui/screens/sports/SportsScreen.kt").readText()
        assertTrue(screen.contains("openGuide = { vm.openGuide { t -> nav.openGuideAt(t) } }")); assertFalse("the plain tab switch is gone", screen.contains("openGuide = { nav.go(Tab.GUIDE) }"))
        val guide = File("src/main/kotlin/app/streamsetu/tv/ui/screens/guide/GuideScreen.kt").readText()
        assertTrue(guide.contains("nav.pendingGuideTarget = null") && guide.contains("fun landed()"))
    }

    // ---- Multi-View's followed hint

    private fun team(sport: Sport, name: String) = D.team(sport, name)

    @Test fun aValidV2FollowShowsTheHint() {
        val live = D.event("a", now - h, listOf("India", "Nepal")); val other = D.event("b", now - h, listOf("Brazil", "Chile"), sport = Sport.FOOTBALL)
        assertEquals(setOf("a"), MultiviewHints.followedIds(FollowSet(listOf(team(Sport.CRICKET, "India"))), listOf(live, other), listOf(live, other)))
    }

    @Test fun sameNamedParticipantsFromUnrelatedSourcesDoNotShareTheHint() {
        val a = D.event("a", now - h, listOf("Lions", "Tigers"), sources = setOf("A")); val b = D.event("b", now - h, listOf("Lions", "Bears"), sources = setOf("B"))
        val all = listOf(a, b); val ix = IdentityIndex.build(all)
        val followB = Follow(FollowKind.PARTICIPANT, Sport.CRICKET, ix.participants(b).first { it.contains("lions") }, "Lions")
        assertEquals("only the playlist the person followed", setOf("b"), MultiviewHints.followedIds(FollowSet(listOf(followB)), all, all))
        val unscoped = Follow(FollowKind.PARTICIPANT, Sport.CRICKET, SportsIdentity.participant(Sport.CRICKET, "Lions")!!, "Lions")
        assertTrue("a plain name that is now ambiguous marks neither", MultiviewHints.followedIds(FollowSet(listOf(unscoped)), all, all).isEmpty())
    }

    @Test fun anUnresolvedOrUnavailableLegacyFollowShowsNoHint() {
        val a = D.event("a", now - h, listOf("Barcelona", "Madrid"), sport = Sport.FOOTBALL); val b = D.event("b", now - h, listOf("Barcelona SC", "Emelec"), sport = Sport.FOOTBALL)
        val legacy = Follow(FollowKind.PARTICIPANT, Sport.FOOTBALL, SportsKeys.key("Barcelona"), "Barcelona")
        assertTrue("fits two teams: neither is marked", MultiviewHints.followedIds(FollowSet(listOf(legacy)), listOf(a, b), listOf(a, b)).isEmpty())
        val gone = Follow(FollowKind.PARTICIPANT, Sport.FOOTBALL, "nobody", "Nobody")
        assertTrue(MultiviewHints.followedIds(FollowSet(listOf(gone)), listOf(a, b), listOf(a, b)).isEmpty())
    }

    @Test fun strictNamesKeepClubsApartInTheHint() {
        val a = D.event("a", now - h, listOf("Barcelona", "Madrid"), sport = Sport.FOOTBALL); val b = D.event("b", now - h, listOf("Barcelona SC", "Emelec"), sport = Sport.FOOTBALL)
        assertEquals(setOf("b"), MultiviewHints.followedIds(FollowSet(listOf(team(Sport.FOOTBALL, "Barcelona SC"))), listOf(a, b), listOf(a, b)))
    }

    @Test fun theScreenUsesTheScopedResolverNotTheBareFollowSet() {
        val t = File("src/main/kotlin/app/streamsetu/tv/ui/screens/sports/SportsMultiviewScreen.kt").readText()
        assertTrue(t.contains("MultiviewHints.followedIds(") && !t.contains("followSet.matches("))
    }
}
