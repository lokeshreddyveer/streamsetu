package app.streamsetu.core.sync.lan

import java.math.BigInteger
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.PublicKey
import java.security.SecureRandom
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import java.security.spec.PKCS8EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * The cryptography of sync on this network, as written in docs/WIFI-SYNC.md: a long-term P-256 key for each device, a shared secret from ECDH, a session key and
 * the six comparison digits from HKDF-SHA256, and AES-256-GCM for every frame after the hello. The Apple apps do the same, so the two can talk to each other.
 */
object LanCrypto {
    private val random = SecureRandom()
    private val curve: ECParameterSpec by lazy {
        AlgorithmParameters.getInstance("EC").apply { init(ECGenParameterSpec("secp256r1")) }.getParameterSpec(ECParameterSpec::class.java)
    }

    class Identity(val privatePkcs8: ByteArray, val publicX963: ByteArray) { val deviceId: String get() = deviceId(publicX963) }

    fun newIdentity(): Identity {
        val pair = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
        return Identity(pair.private.encoded, x963(pair.public as ECPublicKey))
    }

    fun randomBytes(n: Int): ByteArray = ByteArray(n).also { random.nextBytes(it) }

    fun deviceId(publicX963: ByteArray): String = sha256(publicX963).take(8).joinToString("") { "%02x".format(it) }

    fun sha256(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)

    /** `04 || X || Y`, each 32 bytes. */
    fun x963(key: ECPublicKey): ByteArray {
        fun fixed(v: BigInteger): ByteArray { val b = v.toByteArray(); return if (b.size == 33 && b[0] == 0.toByte()) b.copyOfRange(1, 33) else ByteArray(32 - b.size) + b }
        return byteArrayOf(4) + fixed(key.w.affineX) + fixed(key.w.affineY)
    }

    fun publicKey(x963: ByteArray): PublicKey {
        require(x963.size == 65 && x963[0] == 4.toByte()) { "not a P-256 public key" }
        val point = ECPoint(BigInteger(1, x963.copyOfRange(1, 33)), BigInteger(1, x963.copyOfRange(33, 65)))
        return KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(point, curve))
    }

    fun privateKey(pkcs8: ByteArray): PrivateKey = KeyFactory.getInstance("EC").generatePrivate(PKCS8EncodedKeySpec(pkcs8))

    /** The 32-byte shared secret between our private key and the other device's public key. */
    fun sharedSecret(privatePkcs8: ByteArray, peerX963: ByteArray): ByteArray =
        KeyAgreement.getInstance("ECDH").apply { init(privateKey(privatePkcs8)); doPhase(publicKey(peerX963), true) }.generateSecret()

    fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        fun hmac(key: ByteArray, data: ByteArray) = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(key, "HmacSHA256")) }.doFinal(data)
        val prk = hmac(if (salt.isEmpty()) ByteArray(32) else salt, ikm)
        var block = ByteArray(0); val out = java.io.ByteArrayOutputStream(); var counter = 1
        while (out.size() < length) { block = hmac(prk, block + info + byteArrayOf(counter.toByte())); out.write(block); counter++ }
        return out.toByteArray().copyOf(length)
    }

    fun sessionKey(z: ByteArray, nonceInitiator: ByteArray, nonceResponder: ByteArray): ByteArray =
        hkdf(z, nonceInitiator + nonceResponder, "streamsetu-sync-v1 session".toByteArray(), 32)

    /** The six digits both people compare while pairing. */
    fun comparisonDigits(z: ByteArray, publicInitiator: ByteArray, publicResponder: ByteArray): String {
        val b = hkdf(z, publicInitiator + publicResponder, "streamsetu-sync-v1 sas".toByteArray(), 4)
        val n = ((b[0].toLong() and 0xff) shl 24) or ((b[1].toLong() and 0xff) shl 16) or ((b[2].toLong() and 0xff) shl 8) or (b[3].toLong() and 0xff)
        return "%06d".format(n % 1_000_000)
    }

    /** One direction of an encrypted connection: [sending] is 0 for what the initiator sends and 1 for what the responder sends. Every frame uses the next counter. */
    class Channel(private val key: ByteArray, private val sending: Int) {
        private var sent = 0L
        private var received = 0L

        fun seal(plain: ByteArray): ByteArray {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce(sending, sent++)))
            return cipher.doFinal(plain)
        }

        fun open(frame: ByteArray): ByteArray {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce(1 - sending, received)))
            return cipher.doFinal(frame).also { received++ }
        }

        private fun nonce(direction: Int, counter: Long): ByteArray {
            val n = ByteArray(12)
            n[3] = direction.toByte()
            for (i in 0 until 8) n[11 - i] = (counter ushr (8 * i)).toByte()
            return n
        }
    }
}
