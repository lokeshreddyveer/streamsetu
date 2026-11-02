package app.streamsetu.core.addon

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okio.ByteString.Companion.decodeBase64
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.Signature
import java.security.spec.X509EncodedKeySpec

/** One add-on the app's own list approves. [sha256] is the fingerprint of its description: the add-on is official only while its description is exactly the approved one. */
@Serializable data class OfficialEntry(val id: String, val name: String, val manifestUrl: String, val sha256: String)
/** [sequence] only ever goes up from one signed list to the next; [updated] is for display. */
@Serializable data class OfficialList(val schema: Int, val sequence: Long = 0, val updated: String = "", val addons: List<OfficialEntry> = emptyList())

/**
 * The list of official add-ons is a signed file kept with the app's releases. The app checks its signature against the public key built into the app before it believes a word of it,
 * so nobody who can change the file's address, or the server it is on, can make an add-on look official. The signature is ECDSA with P-256 and SHA-256, which every Android version
 * the app supports can check without adding a library. The private half of the key is kept offline and is never part of the app or the repository.
 */
object OfficialAddons {
    const val LIST_URL = "https://raw.githubusercontent.com/lokeshreddyveer/streamsetu/main/addons/registry.json"
    const val SIGNATURE_URL = "https://raw.githubusercontent.com/lokeshreddyveer/streamsetu/main/addons/registry.json.sig"
    /** X.509 (DER, Base64) public key of the list's signer. */
    const val PUBLIC_KEY = "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEk9Va5o0Jaqg10QOwRf/zfyGSxvxb+JmakeRCO8cBnsSYrl6zynQiET5ZFSF9wm98TfIWXrCay2dBsE+JSQNuug=="
    private val json = Json { ignoreUnknownKeys = false }

    fun verify(text: String, signatureBase64: String, publicKeyBase64: String = PUBLIC_KEY): Boolean = try {
        val key = KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(decode(publicKeyBase64)))
        Signature.getInstance("SHA256withECDSA").run { initVerify(key); update(text.toByteArray(Charsets.UTF_8)); verify(decode(signatureBase64.trim())) }
    } catch (e: Exception) { false }

    /** The list itself, once its signature has been checked. An [AddonException] says why it cannot be used. */
    fun verifiedList(text: String, signatureBase64: String, publicKeyBase64: String = PUBLIC_KEY): OfficialList {
        if (!verify(text, signatureBase64, publicKeyBase64)) throw AddonException("The list of official add-ons could not be verified, so it was not used.")
        val list = try { json.decodeFromString(OfficialList.serializer(), text) } catch (e: Exception) { throw AddonException("The list of official add-ons is not in a form this version understands.") }
        if (list.schema != 1) throw AddonException("The list of official add-ons needs a newer version of StreamSetu.")
        return list
    }

    /** The entries of a verified list that this version can use (https address, a full fingerprint). */
    fun entriesOf(list: OfficialList): List<OfficialEntry> = list.addons.filter { AddonManifestParser.hostOf(it.manifestUrl) != null && it.sha256.length == 64 }

    /** The approved add-ons, or an [AddonException] when the signature does not match or the list is not one this version reads. */
    fun parse(text: String, signatureBase64: String, publicKeyBase64: String = PUBLIC_KEY): List<OfficialEntry> = entriesOf(verifiedList(text, signatureBase64, publicKeyBase64))

    /** Where a list came from, in the order they are trusted when more than one is available. */
    enum class Origin(val label: String) { REMOTE("the list server"), CACHED("the last list that was checked"), BUNDLED("the list that came with this version") }
    data class Resolved(val entries: List<OfficialEntry>, val origin: Origin, val updated: String, val sequence: Long, val note: String?)

    /**
     * Chooses which list to use. A newer verified list from the server wins; one that is older than a list already verified (a rollback) is ignored; when the server cannot be reached
     * or its list does not verify, the newest verified list the app already has is used and the note says so. It never ends in an empty list because something failed: no usable list
     * at all is an error, and an empty list is only ever a list that was signed empty.
     */
    fun resolve(remote: OfficialList?, remoteProblem: String?, cached: OfficialList?, bundled: OfficialList?, highestAccepted: Long = 0): Resolved {
        val have = listOfNotNull(cached?.let { Origin.CACHED to it }, bundled?.let { Origin.BUNDLED to it })
        // A list older than one already accepted is never shown again, not even the one that came with the app: it may still hold an add-on that a later list withdrew.
        val local = have.filter { it.second.sequence >= highestAccepted }.maxWithOrNull(compareBy({ it.second.sequence }, { it.first == Origin.CACHED }))
        val floor = maxOf(highestAccepted, local?.second?.sequence ?: 0L)
        // A list from the server replaces what the app has only when its number is higher than every list the app has ever accepted: an old signed list can never come back.
        if (remote != null && remote.sequence > floor) return Resolved(entriesOf(remote), Origin.REMOTE, remote.updated, remote.sequence, null)
        if (local == null) throw AddonException(if (have.isNotEmpty() || (remote != null && remote.sequence < floor)) "No list that is as new as one already accepted is available. A newer verified list is needed." else (remoteProblem ?: "The list of official add-ons could not be verified, so it was not used."))
        val note = when {
            remote != null && remote.sequence < floor -> "The server's list is older than one already checked, so it was not used."
            remote != null -> null          // the same list: nothing newer, nothing wrong
            else -> remoteProblem?.let { "The list server could not be used ($it). Showing ${local.first.label}." }
        }
        return Resolved(entriesOf(local.second), local.first, local.second.updated, local.second.sequence, note)
    }

    /** The newest list the app already has, with no network: shown at once while the server is asked. */
    fun local(cached: OfficialList?, bundled: OfficialList?, highestAccepted: Long = 0): Resolved = resolve(null, null, cached, bundled, highestAccepted)

    fun sha256Hex(text: String): String = MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }

    /** okio decodes Base64 the same on a device and in a plain test (java.util.Base64 needs Android 8). */
    private fun decode(s: String): ByteArray = s.filter { !it.isWhitespace() }.decodeBase64()?.toByteArray() ?: throw IllegalArgumentException("not Base64")
}
