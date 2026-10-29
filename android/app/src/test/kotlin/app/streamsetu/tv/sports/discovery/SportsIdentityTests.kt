package app.streamsetu.tv.sports.discovery

import app.streamsetu.core.sports.Sport
import app.streamsetu.tv.sports.personal.FollowKind
import app.streamsetu.tv.sports.personal.SportsKeys
import org.junit.Assert.*
import org.junit.Test

class SportsIdentityTests {
    private val h = D.H

    @Test fun clubMarkersAreKeptSoDistinctOrganizationsStaySeparate() {
        assertNotEquals(SportsIdentity.participant(Sport.FOOTBALL, "Barcelona"), SportsIdentity.participant(Sport.FOOTBALL, "Barcelona SC"))
        assertNotEquals(SportsIdentity.participant(Sport.FOOTBALL, "Athletic"), SportsIdentity.participant(Sport.FOOTBALL, "Athletic Club"))
        assertNotEquals(SportsIdentity.participant(Sport.FOOTBALL, "Real Madrid"), SportsIdentity.participant(Sport.FOOTBALL, "Real Madrid CF"))
        assertNotEquals(SportsIdentity.participant(Sport.FOOTBALL, "The Strongest"), SportsIdentity.participant(Sport.FOOTBALL, "Strongest"))
        // the classifier's own key is unchanged: it still folds these (reminders and recordings match by it)
        assertEquals(SportsKeys.key("Barcelona"), SportsKeys.key("Barcelona SC"))
    }

    @Test fun caseAccentsPunctuationAndSpacesDoNotMakeANewIdentity() {
        val k = SportsIdentity.participant(Sport.FOOTBALL, "Atlético  Madrid")
        assertEquals(k, SportsIdentity.participant(Sport.FOOTBALL, "ATLETICO MADRID"))
        assertEquals(k, SportsIdentity.participant(Sport.FOOTBALL, "atletico-madrid."))
        assertEquals("v2:participant:football:atletico madrid", k)
        assertEquals("v2:competition:football:la liga", SportsIdentity.competition(Sport.FOOTBALL, " La   Liga "))
        assertNull("nothing left of the name", SportsIdentity.participant(Sport.FOOTBALL, " ... "))
    }

    @Test fun theSameNameInAnotherSportIsAnotherIdentity() {
        assertNotEquals(SportsIdentity.participant(Sport.FOOTBALL, "Warriors"), SportsIdentity.participant(Sport.RUGBY, "Warriors"))
        assertNotEquals(SportsIdentity.competition(Sport.FOOTBALL, "Premier League"), SportsIdentity.competition(Sport.CRICKET, "Premier League"))
    }

    @Test fun oneTeamOnManyFeedsAndPlaylistsThatShareTheEventIsOneIdentity() {
        val e = D.event("e1", D.NOW + h, listOf("India", "Australia"), sources = setOf("A", "B"), channels = listOf("x", "y"))
        val ix = IdentityIndex.build(listOf(e))
        assertEquals(2, ix.participants(e).size)
        assertTrue("no playlist scope: the playlists carry the same event", ix.participants(e).none { SportsIdentity.isScoped(it) })
        assertEquals(0, ix.ambiguousCount)
    }

    @Test fun theSameTeamInTwoCompetitionsIsOneTeamAndTwoCompetitions() {
        val a = D.event("a", D.NOW + h, listOf("India", "Nepal"), competition = "Asia Cup"); val b = D.event("b", D.NOW + 30 * h, listOf("India", "Chile"), competition = "World Cup")
        val ix = IdentityIndex.build(listOf(a, b))
        assertEquals(ix.participants(a).first { it.endsWith("india") }, ix.participants(b).first { it.endsWith("india") })
        assertNotEquals(ix.competition(a), ix.competition(b))
    }

    @Test fun theSameExactNameFromPlaylistsThatShareNoEventStaysSeparate() {
        val a = D.event("a", D.NOW + h, listOf("Lions", "Tigers"), sources = setOf("A")); val b = D.event("b", D.NOW + 20 * h, listOf("Lions", "Bears"), sources = setOf("B"))
        val ix = IdentityIndex.build(listOf(a, b))
        val la = ix.participants(a).first { SportsIdentity.base(it).endsWith("lions") }; val lb = ix.participants(b).first { SportsIdentity.base(it).endsWith("lions") }
        assertNotEquals("nothing shows they are one team", la, lb)
        assertTrue(SportsIdentity.isScoped(la) && SportsIdentity.isScoped(lb)); assertTrue(ix.isAmbiguous(SportsIdentity.base(la)))
        assertEquals("a name that is only in one playlist is not scoped", ix.participants(a).first { it.endsWith("tigers") }, SportsIdentity.participant(Sport.CRICKET, "Tigers"))
        assertEquals(listOf(la, lb).sorted(), ix.expand(SportsIdentity.base(la)))
    }

    @Test fun anEventBothPlaylistsCarryIsTheEvidenceThatTheyMeanTheSameTeam() {
        val shared = D.event("s", D.NOW + h, listOf("Lions", "Tigers"), sources = setOf("A", "B"), channels = listOf("x"))
        val onlyB = D.event("b", D.NOW + 20 * h, listOf("Lions", "Bears"), sources = setOf("B"))
        val ix = IdentityIndex.build(listOf(shared, onlyB))
        assertTrue("A and B overlap, so Lions is one team", ix.participants(shared).none { SportsIdentity.isScoped(it) } && ix.participants(onlyB).none { SportsIdentity.isScoped(it) })
    }

    @Test fun missingParticipantsAndCompetitionsAreNotInvented() {
        val e = D.event("g", D.NOW + h, emptyList(), competition = null)
        val ix = IdentityIndex.build(listOf(e))
        assertTrue(ix.participants(e).isEmpty()); assertNull(ix.competition(e)); assertEquals(0, ix.identityCount)
    }

    @Test fun anOldKeyListsEveryStrictIdentityItCouldMean() {
        val a = D.event("a", D.NOW + h, listOf("Barcelona", "Madrid"), sport = Sport.FOOTBALL); val b = D.event("b", D.NOW + 30 * h, listOf("Barcelona SC", "Emelec"), sport = Sport.FOOTBALL)
        val ix = IdentityIndex.build(listOf(a, b))
        val c = ix.legacyCandidates(FollowKind.PARTICIPANT, Sport.FOOTBALL, SportsKeys.key("Barcelona"))
        assertEquals(listOf("v2:participant:football:barcelona", "v2:participant:football:barcelona sc"), c)
        assertTrue(ix.legacyCandidates(FollowKind.PARTICIPANT, Sport.FOOTBALL, "nobody").isEmpty())
    }

    @Test fun theIndexIsTheSameWhateverTheOrderOfEventsOrFeeds() {
        val a = D.event("a", D.NOW + h, listOf("Lions", "Tigers"), sources = setOf("A")); val b = D.event("b", D.NOW + 20 * h, listOf("Lions", "Bears"), sources = setOf("B"))
        val one = IdentityIndex.build(listOf(a, b)); val two = IdentityIndex.build(listOf(b, a))
        assertEquals(one.participants(a), two.participants(a)); assertEquals(one.participants(b), two.participants(b))
    }
}
