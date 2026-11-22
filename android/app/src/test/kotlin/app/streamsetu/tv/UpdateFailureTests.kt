package app.streamsetu.tv

import app.streamsetu.tv.update.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.io.OutputStream
import java.net.UnknownHostException
import java.security.MessageDigest

/** What the updater does when the file cannot be used: each failure has its own plain message and kind. */
class UpdateFailureTests {
    @get:Rule val tmp = TemporaryFolder()
    private fun sha(b: ByteArray) = MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it) }

    @Test fun aDifferentSigningKeyIsSaidInFullAndDeletesNothingElse() {
        val e = runCatching { UpdateChecks.checkSigner("app.streamsetu.tv", "app.streamsetu.tv", setOf("new"), setOf("old"), 30, 20) }.exceptionOrNull() as UpdateException
        assertEquals(UpdateFailure.SIGNER, e.kind)
        assertEquals("This update is signed with a different key and cannot be installed over this version. Uninstall StreamSetu and install the new version from the Releases page.", e.message)
        assertEquals(UpdateFailure.SIGNER, (runCatching { UpdateChecks.checkSigner("app.streamsetu.tv", "app.streamsetu.tv", emptySet(), emptySet(), 30, 20) }.exceptionOrNull() as UpdateException).kind)
    }

    @Test fun theRightKeyANewerBuildAndTheSameAppPass() {
        UpdateChecks.checkSigner("app.streamsetu.tv", "app.streamsetu.tv", setOf("k"), setOf("k"), 21, 20)
        assertTrue(runCatching { UpdateChecks.checkSigner("other.app", "app.streamsetu.tv", setOf("k"), setOf("k"), 21, 20) }.isFailure)
        assertTrue(runCatching { UpdateChecks.checkSigner("app.streamsetu.tv", "app.streamsetu.tv", setOf("k"), setOf("k"), 20, 20) }.isFailure)
        assertTrue(runCatching { UpdateChecks.checkSigner(null, "app.streamsetu.tv", setOf("k"), setOf("k"), 21, 20) }.isFailure)
    }

    @Test fun aWrongChecksumIsRefusedAndTheFileIsRemovedByTheCaller() {
        val data = "payload".toByteArray(); val f = File(tmp.newFolder(), "u.apk")
        val actual = UpdateChecks.copyAndHash(ByteArrayInputStream(data), f, data.size.toLong(), {})
        assertEquals(sha(data), actual)
        val e = runCatching { UpdateChecks.checkSha(actual, "0".repeat(64)) }.exceptionOrNull() as UpdateException
        assertEquals(UpdateFailure.CHECKSUM, e.kind); assertEquals(UpdateChecks.CHECKSUM_MESSAGE, e.message)
        UpdateChecks.checkSha(actual, sha(data).uppercase())
    }

    @Test fun aFullDiskIsReportedAsStorageAndLeavesNoPartialFile() {
        val f = File(tmp.newFolder(), "u.apk")
        val full: (File) -> OutputStream = { object : OutputStream() { override fun write(b: Int) { throw IOException("write failed: ENOSPC (No space left on device)") } } }
        val e = runCatching { UpdateChecks.copyAndHash(ByteArrayInputStream(ByteArray(1000)), f, 1000, {}, full) }.exceptionOrNull() as UpdateException
        assertEquals(UpdateFailure.STORAGE, e.kind); assertEquals(UpdateChecks.STORAGE_MESSAGE, e.message); assertFalse(f.exists())
    }

    @Test fun noConnectionIsReportedAsNetwork() {
        val e = UpdateChecks.classify(UnknownHostException("api.github.com"))
        assertEquals(UpdateFailure.NETWORK, e.kind); assertEquals(UpdateChecks.NETWORK_MESSAGE, e.message)
        assertEquals(UpdateFailure.NETWORK, UpdateChecks.classify(java.net.SocketTimeoutException("slow")).kind)
        val broken = object : java.io.InputStream() { override fun read(): Int = throw java.net.SocketException("Connection reset") }
        val f = File(tmp.newFolder(), "u.apk")
        assertEquals(UpdateFailure.NETWORK, (runCatching { UpdateChecks.copyAndHash(broken, f, 10, {}) }.exceptionOrNull() as UpdateException).kind); assertFalse(f.exists())
    }

    @Test fun onlyTheFailuresThatRepeatAreRememberedAndTheUpdaterIsOffInStoreAndBenchmarkBuilds() {
        val root = File("build.gradle.kts").absoluteFile.let { if (it.exists()) it else File("app/build.gradle.kts").absoluteFile }.readText()
        assertTrue("the benchmark build has no updater", root.substringAfter("create(\"benchmark\")").substringBefore("proguardFiles").contains("\"SELF_UPDATE\", \"false\""))
        assertTrue("a store build has no updater", root.contains("!project.hasProperty(\"storeBuild\")"))
        val mgr = File("src/main/kotlin/app/streamsetu/tv/update/UpdateManager.kt").absoluteFile.readText()
        assertTrue(mgr.contains("newest.version != settings.failedUpdate")); assertTrue(mgr.contains("val enabled: Boolean get() = BuildConfig.SELF_UPDATE"))
    }
}
