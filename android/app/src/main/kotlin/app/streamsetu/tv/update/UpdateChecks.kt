package app.streamsetu.tv.update

import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.ConnectException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.security.MessageDigest

/** Why an update could not be used, so the person is told in plain words and the right thing is done about it. */
enum class UpdateFailure { SIGNER, CHECKSUM, NETWORK, STORAGE, OTHER }

class UpdateException(val kind: UpdateFailure, message: String) : Exception(message)

/** The checks of a downloaded update, kept apart from the system calls so each can be tried on its own. */
object UpdateChecks {
    const val SIGNER_MESSAGE = "This update is signed with a different key and cannot be installed over this version. Uninstall StreamSetu and install the new version from the Releases page."
    const val CHECKSUM_MESSAGE = "The download did not match its checksum, so it was not installed. Try again later; if it keeps happening, install it from the Releases page."
    const val NETWORK_MESSAGE = "The update could not be downloaded: there is no working connection. Check the network and try again."
    const val STORAGE_MESSAGE = "There is not enough free space on this device to download the update. Free some space and try again."

    /** The file's own SHA-256 must be the one in the release notes. */
    fun checkSha(actual: String, expected: String) { if (!actual.equals(expected, ignoreCase = true)) throw UpdateException(UpdateFailure.CHECKSUM, CHECKSUM_MESSAGE) }

    /** Same app, same signing key, and a newer build. A different key says so in full (the installer would refuse it anyway, without a reason). */
    fun checkSigner(archivePackage: String?, ownPackage: String, archiveCerts: Set<String>, installedCerts: Set<String>, archiveCode: Long, installedCode: Long) {
        if (archivePackage == null) throw UpdateException(UpdateFailure.OTHER, "The downloaded file is not a valid app.")
        if (archivePackage != ownPackage) throw UpdateException(UpdateFailure.OTHER, "The downloaded file is for a different app, so it was not installed.")
        if (archiveCerts.isEmpty() || archiveCerts != installedCerts) throw UpdateException(UpdateFailure.SIGNER, SIGNER_MESSAGE)
        if (archiveCode <= installedCode) throw UpdateException(UpdateFailure.OTHER, "The downloaded build is not newer than the installed one.")
    }

    /** What went wrong while reading or writing the file, in terms of the person's problem. */
    fun classify(e: Throwable): UpdateException = when {
        e is UpdateException -> e
        e is UnknownHostException || e is ConnectException || e is SocketTimeoutException || (e is SocketException) -> UpdateException(UpdateFailure.NETWORK, NETWORK_MESSAGE)
        e is IOException && (e.message.orEmpty().contains("ENOSPC", true) || e.message.orEmpty().contains("No space left", true) || e.message.orEmpty().contains("not enough space", true)) -> UpdateException(UpdateFailure.STORAGE, STORAGE_MESSAGE)
        e is IOException -> UpdateException(UpdateFailure.NETWORK, NETWORK_MESSAGE)
        else -> UpdateException(UpdateFailure.OTHER, e.message ?: "The update could not be downloaded.")
    }

    /** Copies [input] to [file] while adding up its SHA-256; returns the hash. A partial file is removed when anything fails. */
    fun copyAndHash(input: InputStream, file: File, total: Long, onPercent: (Int) -> Unit, output: (File) -> OutputStream = { it.outputStream() }): String {
        val digest = MessageDigest.getInstance("SHA-256")
        try {
            input.use { i -> output(file).use { out ->
                val buf = ByteArray(64 * 1024); var done = 0L; var last = -1
                while (true) {
                    val n = i.read(buf); if (n < 0) break
                    out.write(buf, 0, n); digest.update(buf, 0, n); done += n
                    if (total > 0) { val pct = (done * 100 / total).toInt().coerceIn(0, 100); if (pct != last) { last = pct; onPercent(pct) } }
                }
            } }
        } catch (e: Exception) { file.delete(); throw classify(e) }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
}
