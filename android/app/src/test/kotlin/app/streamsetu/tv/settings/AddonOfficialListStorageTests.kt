package app.streamsetu.tv.settings

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import app.streamsetu.core.addon.AddonClient
import app.streamsetu.core.addon.AddonException
import app.streamsetu.core.addon.OfficialAddons
import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.repo.AddonRegistry
import app.streamsetu.core.data.repo.SourceRepository
import app.streamsetu.core.security.InMemoryCredentialStore
import kotlinx.coroutines.runBlocking
import okio.ByteString.Companion.toByteString
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.security.KeyPairGenerator
import java.security.Signature
import java.security.spec.ECGenParameterSpec

/** The official list through the real repository and its saved preferences: offline first, the server asked afterwards, and the highest number accepted is remembered across restarts. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class AddonOfficialListStorageTests {
    private val ctx get() = ApplicationProvider.getApplicationContext<Context>()
    private lateinit var db: AppDatabase
    private val pair = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
    private val publicKey = pair.public.encoded.toByteString().base64()
    private fun sign(text: String, key: java.security.PrivateKey = pair.private) = Signature.getInstance("SHA256withECDSA").run { initSign(key); update(text.toByteArray()); sign() }.toByteString().base64()
    private fun list(seq: Long, vararg ids: String) = """{"schema":1,"sequence":$seq,"updated":"2026-11-0$seq","addons":[${ids.joinToString(",") { """{"id":"$it","name":"$it","manifestUrl":"https://example.com/$it.json","sha256":"${"b".repeat(64)}"}""" }}]}"""

    private class FakeServer : AddonClient() {
        var text: String? = null; var sig: String? = null; var down = false; var calls = 0
        override fun fetchManifest(url: String): String { calls++; if (down) throw AddonException("no answer"); return (if (url.endsWith(".sig")) sig else text) ?: throw AddonException("no answer") }
    }

    private val server = FakeServer()
    private var bundled: Pair<String, String>? = null          // the list that "came with the app", signed with the test key
    private fun registry() = AddonRegistry(ctx, db, SourceRepository(db, InMemoryCredentialStore()), InMemoryCredentialStore(), server, publicKey, bundledSource = bundled?.let { b -> { b } } ?: { error("no bundled list") })

    @Before fun open() {
        ctx.getSharedPreferences("addons", Context.MODE_PRIVATE).edit().clear().commit()
        db = Room.inMemoryDatabaseBuilder(ctx, AppDatabase::class.java).allowMainThreadQueries().build()
    }
    @After fun close() = db.close()

    private fun serve(text: String, signature: String = sign(text)) { server.text = text; server.sig = signature; server.down = false }

    @Test fun aNewerSignedListIsKeptAndStillThereAfterARestartWithTheServerDown() = runBlocking {
        serve(list(5, "alpha"))
        val first = registry().refreshOfficial()
        assertEquals(OfficialAddons.Origin.REMOTE, first.origin); assertEquals(listOf("alpha"), first.entries.map { it.id })
        server.down = true
        val afterRestart = registry().localOfficial()          // a new object on the same saved preferences
        assertEquals(OfficialAddons.Origin.CACHED, afterRestart.origin); assertEquals(5, afterRestart.sequence); assertEquals(listOf("alpha"), afterRestart.entries.map { it.id })
        assertEquals("the saved list is shown without asking the server", 1 + 1, server.calls)          // only the two requests of the first refresh
    }

    @Test fun anOlderSignedListIsRefusedAfterANewerOneWasAcceptedEvenAfterARestart() = runBlocking {
        serve(list(5, "alpha")); registry().refreshOfficial()
        serve(list(3, "old"))                                   // genuinely signed, but older
        val r = registry().refreshOfficial()
        assertEquals(listOf("alpha"), r.entries.map { it.id }); assertTrue(r.note!!.contains("older"))
        assertEquals(5, registry().localOfficial().sequence)
    }

    @Test fun theHighestNumberIsRememberedEvenIfTheSavedListIsLost() = runBlocking {
        serve(list(7, "alpha")); registry().refreshOfficial()
        ctx.getSharedPreferences("addons", Context.MODE_PRIVATE).edit().remove("official.list").remove("official.sig").commit()
        serve(list(4, "older"))
        try { registry().refreshOfficial(); fail("an older list was accepted") } catch (_: AddonException) {}
        serve(list(8, "newer")); assertEquals(listOf("newer"), registry().refreshOfficial().entries.map { it.id })
    }

    @Test fun anOlderBundledListIsNeverShownAgainOnceANewerOneWasAcceptedAndItsSavedCopyIsLost() = runBlocking {
        bundled = list(1, "withdrawn-later").let { it to sign(it) }
        serve(list(7, "current")); registry().refreshOfficial()
        ctx.getSharedPreferences("addons", Context.MODE_PRIVATE).edit().remove("official.list").remove("official.sig").commit()      // the saved copy is gone; the number stays
        try { registry().localOfficial(); fail("the older bundled list was shown") } catch (_: AddonException) {}
        serve(list(4, "rollback")); try { registry().refreshOfficial(); fail("a rollback was accepted") } catch (_: AddonException) {}
        serve(list(8, "newer")); assertEquals(8, registry().refreshOfficial().sequence); assertEquals(listOf("newer"), registry().localOfficial().entries.map { it.id })
    }

    /** Storage whose commit fails, as a full or failing disk does. */
    private class FailingPrefs(private val real: android.content.SharedPreferences) : android.content.SharedPreferences by real {
        override fun edit(): android.content.SharedPreferences.Editor = object : android.content.SharedPreferences.Editor {
            val e = real.edit()
            override fun putString(k: String?, v: String?) = apply { e.putString(k, v) }
            override fun putLong(k: String?, v: Long) = apply { e.putLong(k, v) }
            override fun putStringSet(k: String?, v: MutableSet<String>?) = apply { e.putStringSet(k, v) }
            override fun putInt(k: String?, v: Int) = apply { e.putInt(k, v) }
            override fun putFloat(k: String?, v: Float) = apply { e.putFloat(k, v) }
            override fun putBoolean(k: String?, v: Boolean) = apply { e.putBoolean(k, v) }
            override fun remove(k: String?) = apply { e.remove(k) }
            override fun clear() = apply { e.clear() }
            override fun commit() = false          // nothing is written
            override fun apply() {}
        }
    }

    @Test fun aNewerListThatCannotBeSavedIsNotAcceptedAndTheOldNumberStands() = runBlocking {
        serve(list(3, "alpha")); registry().refreshOfficial()
        val failing = AddonRegistry(ctx, db, SourceRepository(db, InMemoryCredentialStore()), InMemoryCredentialStore(), server, publicKey, storage = FailingPrefs(ctx.getSharedPreferences("addons", Context.MODE_PRIVATE)))
        serve(list(9, "beta"))
        try { failing.refreshOfficial(); fail("a list that could not be saved was accepted") } catch (e: AddonException) { assertTrue(e.message!!, e.message!!.contains("could not be saved")) }
        val after = registry().localOfficial(); assertEquals(3, after.sequence); assertEquals(listOf("alpha"), after.entries.map { it.id })
    }

    @Test fun anUnreachableServerLeavesTheLastVerifiedListWithANoteAndNeverAnEmptyOne() = runBlocking {
        serve(list(2, "alpha")); registry().refreshOfficial()
        server.down = true
        val r = registry().refreshOfficial()
        assertEquals(listOf("alpha"), r.entries.map { it.id }); assertTrue(r.note!!.contains("could not be used"))
    }

    @Test fun aListWithABadSignatureIsNotUsedAndNeverReplacesAGoodOne() = runBlocking {
        serve(list(2, "alpha")); registry().refreshOfficial()
        val other = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
        serve(list(9, "forged"), sign(list(9, "forged"), other.private))
        val r = registry().refreshOfficial()
        assertEquals(listOf("alpha"), r.entries.map { it.id }); assertEquals(2, registry().localOfficial().sequence)
    }

    @Test fun aSignedEmptyListIsAnEmptyListAndNothingElseIs() = runBlocking {
        serve(list(1))
        val r = registry().refreshOfficial()
        assertTrue(r.entries.isEmpty()); assertEquals(OfficialAddons.Origin.REMOTE, r.origin); assertNull(r.note)
    }
}
