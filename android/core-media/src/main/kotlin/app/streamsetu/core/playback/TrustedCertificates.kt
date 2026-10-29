package app.streamsetu.core.playback

import android.content.Context
import android.util.Base64
import java.io.File
import java.security.KeyStore
import java.security.cert.X509Certificate

/**
 * libmpv has no list of trusted certificate authorities of its own. This writes the ones the device trusts (the system store) into one PEM file that it can be pointed at.
 * It is rewritten when the system store changes (updated by the number and names of the certificates), and left alone otherwise.
 */
object TrustedCertificates {
    fun file(context: Context): File? = runCatching {
        val store = KeyStore.getInstance("AndroidCAStore").apply { load(null) }
        val certs = store.aliases().toList().mapNotNull { (store.getCertificate(it) as? X509Certificate) }
        if (certs.isEmpty()) return null
        val out = File(context.applicationContext.cacheDir, "trusted-certificates.pem")
        val stamp = certs.size.toString() + ":" + certs.sumOf { it.serialNumber.hashCode().toLong() }
        val marker = File(out.path + ".stamp")
        if (out.exists() && marker.exists() && marker.readText() == stamp) return out
        out.bufferedWriter().use { w ->
            for (c in certs) {
                w.write("-----BEGIN CERTIFICATE-----\n")
                w.write(Base64.encodeToString(c.encoded, Base64.NO_WRAP).chunked(64).joinToString("\n"))
                w.write("\n-----END CERTIFICATE-----\n")
            }
        }
        marker.writeText(stamp)
        out
    }.getOrNull()
}
