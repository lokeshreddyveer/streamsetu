package app.streamsetu.tv.sports.personal

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.db.SportsFollowEntity
import app.streamsetu.core.model.Channel
import app.streamsetu.core.sports.Sport
import app.streamsetu.tv.sports.discovery.D
import app.streamsetu.tv.sports.discovery.IdentityIndex
import app.streamsetu.tv.sports.discovery.SportsIdentity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Old follows were kept by the classifier's key. Against the guide, one that fits exactly one strict identity becomes it, once; the others are never guessed, merged or deleted. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class SportsFollowMigrationTests {
    private lateinit var db: AppDatabase
    private lateinit var d: FakeReminderDeps
    private lateinit var follows: SportsFollowService
    private val now = D.NOW; private val h = D.H

    @Before fun open() {
        db = Room.inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext(), AppDatabase::class.java).allowMainThreadQueries().build()
        d = FakeReminderDeps(); d.time = now
        follows = SportsFollowService(db.sports(), d, d.profileFlow, { }) { now }
    }
    @After fun close() { db.close() }

    private fun <T> run(b: suspend () -> T): T = runBlocking { b() }
    private fun legacy(kind: FollowKind, sport: Sport, name: String, profile: String = "main") = SportsFollowEntity(profileId = profile, kind = kind.name, sport = sport.name, normKey = SportsKeys.key(name), displayName = name, createdAt = 1)
    private fun rows(profile: String = "main") = run { db.sports().follows(profile) }
    private fun guide(vararg e: app.streamsetu.core.sports.SportsEvent) = IdentityIndex.build(e.toList()).also { ix -> e.forEach { ev -> ev.feeds.forEach { f -> d.auth.channels[f.channelId] = Channel(f.channelId, f.sourceId, "cat", "Channel", null, null, "ref", null) } } }

    @Test fun anOldFollowThatFitsOneIdentityBecomesItOnceAndKeepsItsName() = run {
        db.sports().insertFollow(legacy(FollowKind.PARTICIPANT, Sport.CRICKET, "Team India"))
        val ix = guide(D.event("e", now + h, listOf("Team India", "Nepal")))
        val first = follows.resolveLegacy(ix); val second = follows.resolveLegacy(ix)
        assertEquals(1, first.upgraded); assertEquals("a second pass changes nothing", 0, second.upgraded)
        val r = rows().single(); assertEquals("v2:participant:cricket:team india", r.normKey); assertEquals("Team India", r.displayName); assertEquals(1L, r.createdAt.coerceAtMost(1))
    }

    @Test fun anOldFollowThatFitsTwoIdentitiesStaysAsItIsAndFollowsNeither() = run {
        db.sports().insertFollow(legacy(FollowKind.PARTICIPANT, Sport.FOOTBALL, "Barcelona"))
        val ix = guide(D.event("a", now + h, listOf("Barcelona", "Madrid"), sport = Sport.FOOTBALL), D.event("b", now + 2 * h, listOf("Barcelona SC", "Emelec"), sport = Sport.FOOTBALL))
        val rep = follows.resolveLegacy(ix)
        assertEquals(0, rep.upgraded); assertEquals(1, rep.unresolved)
        assertEquals(SportsKeys.key("Barcelona"), rows().single().normKey)
        val set = follows.current().withIndex(ix)
        assertTrue("unresolved: matches no event", set.follows.none { f -> listOf(D.event("a", now + h, listOf("Barcelona", "Madrid"), sport = Sport.FOOTBALL)).any { set.matches(it) } })
    }

    @Test fun anOldFollowThatFitsNothingIsKeptNotDeleted() = run {
        db.sports().insertFollow(legacy(FollowKind.COMPETITION, Sport.CRICKET, "Retired Cup"))
        val rep = follows.resolveLegacy(guide(D.event("e", now + h, listOf("India", "Nepal"))))
        assertEquals(1, rep.unavailable); assertEquals(0, rep.upgraded); assertEquals(1, rows().size)
        follows.resolveLegacy(IdentityIndex.EMPTY); assertEquals("an empty guide deletes nothing", 1, rows().size)
    }

    @Test fun racingResolversUpgradeExactlyOnceAndNeverDuplicateOrLose() = run {
        db.sports().insertFollow(legacy(FollowKind.PARTICIPANT, Sport.CRICKET, "India")); db.sports().insertFollow(legacy(FollowKind.COMPETITION, Sport.CRICKET, "Asia Cup"))
        val ix = guide(D.event("e", now + h, listOf("India", "Nepal"), competition = "Asia Cup"))
        val services = (1..6).map { SportsFollowService(db.sports(), d, d.profileFlow, { }) { now } }
        val reports = coroutineScope { services.map { s -> async(Dispatchers.Default) { s.resolveLegacy(ix) } }.awaitAll() }
        assertEquals("each follow moved by exactly one caller", 2, reports.sumOf { it.upgraded })
        val keys = rows().map { it.normKey }.sorted(); assertEquals(listOf("v2:competition:cricket:asia cup", "v2:participant:cricket:india"), keys)
    }

    @Test fun otherProfilesAndSportsAreNotTouched() = run {
        db.sports().insertFollow(legacy(FollowKind.PARTICIPANT, Sport.CRICKET, "India", profile = "kid")); db.sports().insertFollow(legacy(FollowKind.SPORT, Sport.CRICKET, "Cricket").copy(normKey = "cricket"))
        follows.resolveLegacy(guide(D.event("e", now + h, listOf("India", "Nepal"))))
        assertEquals(SportsKeys.key("India"), rows("kid").single().normKey); assertEquals("cricket", rows().single().normKey)
    }

    @Test fun upgradingFollowsRewritesNoReminderAndNoRecording() = run {
        val e = D.event("e", now + 5 * h, listOf("India", "Nepal"))
        val ix = guide(e)
        val reminders = SportsReminderService(db.sports(), d, kotlinx.coroutines.CoroutineScope(Dispatchers.Default), { })
        reminders.create(e)
        db.sports().insertRecording(D.recording("r1", e, "SCHEDULED"))
        db.sports().insertFollow(legacy(FollowKind.PARTICIPANT, Sport.CRICKET, "India"))
        val before = db.sports().reminders("main").toString() to db.sports().recordings("main").toString()
        follows.resolveLegacy(ix)
        assertEquals(before, db.sports().reminders("main").toString() to db.sports().recordings("main").toString())
        assertEquals(1, db.sports().reminders("main").size)
    }

    @Test fun choosingResolvesAnUnresolvedFollowToOneOfItsCandidatesOnly() = run {
        db.sports().insertFollow(legacy(FollowKind.PARTICIPANT, Sport.FOOTBALL, "Barcelona"))
        val ix = guide(D.event("a", now + h, listOf("Barcelona", "Madrid"), sport = Sport.FOOTBALL), D.event("b", now + 2 * h, listOf("Barcelona SC", "Emelec"), sport = Sport.FOOTBALL))
        val f = follows.current().follows.single()
        assertFalse("a key that is not a candidate", follows.choose(f, "v2:participant:football:somebody else", ix))
        assertTrue(follows.choose(f, "v2:participant:football:barcelona sc", ix))
        assertEquals("v2:participant:football:barcelona sc", rows().single().normKey); assertFalse("the old follow is gone, so a repeat does nothing", follows.choose(f, "v2:participant:football:barcelona sc", ix))
    }

    @Test fun newFollowsAreSavedByStrictIdentityAndTheSameStrictNameIsOneFollow() = run {
        val e = D.event("e", now + h, listOf("India", "FC Australia"), competition = "Premier League"); guide(e)
        val ix = IdentityIndex.build(listOf(e))
        assertEquals(FollowResult.Followed, follows.follow(e, FollowKind.PARTICIPANT, "FC Australia", ix))
        assertEquals("fc australia is the same strict name", FollowResult.AlreadyFollowing, follows.follow(e, FollowKind.PARTICIPANT, "fc   AUSTRALIA", ix))
        assertEquals("australia is not: the club marker is meaningful", FollowResult.Refused, follows.follow(e, FollowKind.PARTICIPANT, "Australia", ix))
        assertEquals("v2:participant:cricket:fc australia", rows().single().normKey)
        assertTrue(SportsIdentity.isV2(rows().single().normKey))
    }

    @Test fun aNameSharedByUnrelatedPlaylistsIsFollowedAsTheOneInTheEventThatWasOpened() = run {
        val a = D.event("a", now + h, listOf("Lions", "Tigers"), sources = setOf("A")); val b = D.event("b", now + 20 * h, listOf("Lions", "Bears"), sources = setOf("B"))
        val ix = guide(a, b); d.auth.active = setOf("A", "B")
        assertEquals(FollowResult.Followed, follows.follow(b, FollowKind.PARTICIPANT, "Lions", ix))
        val key = rows().single().normKey; assertTrue(SportsIdentity.isScoped(key))
        val set = follows.current().withIndex(ix)
        assertTrue(set.matches(b)); assertFalse("the other playlist's Lions is not the followed team", set.matches(a))
    }
}
