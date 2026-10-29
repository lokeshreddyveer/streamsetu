package app.streamsetu.tv

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.db.Profiles
import app.streamsetu.core.model.PinHash
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.security.MessageDigest

/** A PIN is stored with a slow derivation, in a versioned format that carries its own rounds; the old single-pass form still works and is upgraded. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class PinHashTests {
    private val salt = "salt".toByteArray()
    private fun hex(b: ByteArray) = PinHash.hex(b)

    @Test fun theDerivationIsStandardPbkdf2HmacSha256() {
        assertEquals("120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b", hex(PinHash.derive("password", salt, 1)))
        assertEquals("ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43", hex(PinHash.derive("password", salt, 2)))
        assertEquals("c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a", hex(PinHash.derive("password", salt, 4096)))
        assertEquals("55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783", hex(PinHash.derive("passwd", salt, 1, 64)))
    }

    @Test fun aStoredPinIsVersionedAndCarriesItsRounds() {
        val stored = PinHash.make("1234", "s".toByteArray(), 1000)
        assertTrue(stored.startsWith("pbkdf2-sha256\$1000$"))
        assertEquals(64, stored.substringAfterLast('$').length)
        assertEquals(PinHash.Check.RIGHT, PinHash.verify("1234", "s".toByteArray(), stored))
        assertEquals(PinHash.Check.WRONG, PinHash.verify("1235", "s".toByteArray(), stored))
        assertEquals(PinHash.Check.WRONG, PinHash.verify("1234", "other".toByteArray(), stored))
    }

    @Test fun theRoundsAreMeasuredAndKeptInRange() {
        assertTrue(PinHash.calibratedRounds in PinHash.MIN_ROUNDS..PinHash.MAX_ROUNDS)
        assertTrue(PinHash.make("0000", "s".toByteArray()).startsWith("pbkdf2-sha256\$${PinHash.calibratedRounds}$"))
    }

    @Test fun aPinStoredTheOldWayStillWorksAndIsReportedAsOld() {
        val s = "old-salt".toByteArray()
        val legacy = hex(MessageDigest.getInstance("SHA-256").digest(s + "4321".toByteArray()))
        assertEquals(PinHash.Check.RIGHT_BUT_OLD, PinHash.verify("4321", s, legacy))
        assertEquals(PinHash.Check.WRONG, PinHash.verify("4322", s, legacy))
    }

    @Test fun garbageIsNeverAccepted() {
        for (bad in listOf("", "pbkdf2-sha256\$0\$00", "pbkdf2-sha256\$abc\$00", "pbkdf2-sha256\$1000", "scrypt\$1\$2", "pbkdf2-sha256\$99999999999\$00"))
            assertEquals(bad, PinHash.Check.WRONG, PinHash.verify("1234", "s".toByteArray(), bad))
    }

    private lateinit var db: AppDatabase
    @Before fun open() { db = Room.inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext(), AppDatabase::class.java).allowMainThreadQueries().build() }
    @After fun close() { db.close() }

    @Test fun aProfilePinStoredTheOldWayIsUpgradedOnTheFirstRightEntry() {
        val sdb = db.openHelper.writableDatabase
        Profiles.create(sdb)
        val salt = "legacy-salt"
        val legacy = hex(MessageDigest.getInstance("SHA-256").digest((salt + "2468").toByteArray()))
        sdb.execSQL("INSERT INTO profiles(id, name, kids, pin_salt, pin_hash, color, sort_order, created_at) VALUES('p1', 'Kid', 1, ?, ?, 0, 1, 0)", arrayOf(salt, legacy))
        fun stored() = sdb.query("SELECT pin_hash FROM profiles WHERE id = 'p1'").use { it.moveToFirst(); it.getString(0) }
        assertFalse(Profiles.checkPin(sdb, "p1", "0000")); assertEquals(legacy, stored())
        assertTrue(Profiles.checkPin(sdb, "p1", "2468"))
        assertTrue(stored().startsWith("pbkdf2-sha256$")); assertNotEquals(legacy, stored())
        assertTrue("still right afterwards", Profiles.checkPin(sdb, "p1", "2468"))
        assertFalse(Profiles.checkPin(sdb, "p1", "1111"))
    }

    @Test fun aNewProfilePinIsStoredInTheNewForm() {
        val sdb = db.openHelper.writableDatabase
        Profiles.create(sdb)
        val kid = Profiles.add(sdb, "Anya", true, "1357")!!
        val stored = sdb.query("SELECT pin_hash FROM profiles WHERE id = ?", arrayOf(kid.id)).use { it.moveToFirst(); it.getString(0) }
        assertTrue(stored.startsWith("pbkdf2-sha256$"))
        assertTrue(Profiles.checkPin(sdb, kid.id, "1357")); assertFalse(Profiles.checkPin(sdb, kid.id, "7531"))
    }
}
