package app.streamsetu.tv

import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.net.URLDecoder
import java.security.SecureRandom
import kotlin.concurrent.thread

/** What the phone sent. It is shown on the TV for approval and only then used; the password is never displayed. */
data class PhoneSetup(val type: String, val name: String, val address: String, val user: String, val password: String)

/**
 * A small web page served on the home network so a connection can be typed on a phone instead of with the remote.
 * Safe use: a random one-time code in the link that works for five minutes; only devices on the same private network are answered; one submission is accepted;
 * the TV shows what arrived and the person approves it with the remote. The page travels over plain HTTP inside the home network, so it should only be used at home.
 */
class PhoneSetupServer(private val onReceived: (PhoneSetup) -> Unit) {
    private var server: ServerSocket? = null
    private val token = ByteArray(5).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it) }
    private val expiresAt = System.currentTimeMillis() + 5 * 60_000L
    @Volatile private var used = false
    val secondsLeft: Int get() = ((expiresAt - System.currentTimeMillis()) / 1000).toInt().coerceAtLeast(0)

    /** The address to put in the QR code, or null when the TV has no home-network address. */
    fun start(): String? {
        val ip = localAddress() ?: return null
        val s = ServerSocket(0, 4, InetAddress.getByName("0.0.0.0")); server = s
        thread(isDaemon = true, name = "phone-setup") { while (!s.isClosed && System.currentTimeMillis() < expiresAt) runCatching { handle(s.accept()) } ; stop() }
        return "http://${ip.hostAddress}:${s.localPort}/?t=$token"
    }

    fun stop() { runCatching { server?.close() }; server = null }

    private fun handle(sock: Socket) = thread(isDaemon = true) {
        sock.use {
            runCatching {
                sock.soTimeout = 5000
                val remote = sock.inetAddress
                if (!(remote.isSiteLocalAddress || remote.isLoopbackAddress || remote.isLinkLocalAddress)) return@thread
                val inp = sock.getInputStream().buffered(); val out = sock.getOutputStream()
                val head = StringBuilder(); var last4 = 0
                while (head.length < 8192) { val b = inp.read(); if (b < 0) break; head.append(b.toChar()); last4 = (last4 shl 8) or b; if (last4 == 0x0D0A0D0A) break }
                val lines = head.toString().split("\r\n")
                val (method, path) = lines.first().split(' ').let { it[0] to it.getOrElse(1) { "/" } }
                val length = lines.firstOrNull { it.startsWith("Content-Length:", true) }?.substringAfter(':')?.trim()?.toIntOrNull() ?: 0
                fun send(status: String, body: String) { val b = body.toByteArray(); out.write("HTTP/1.1 $status\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: ${b.size}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".toByteArray()); out.write(b); out.flush() }
                val valid = System.currentTimeMillis() < expiresAt && !used
                if (method == "GET") {
                    val t = path.substringAfter("t=", "").substringBefore('&')
                    if (t == token && valid) send("200 OK", form()) else send("403 Forbidden", page("This link has expired", "Start again on the TV."))
                } else if (method == "POST" && length in 1..8192) {
                    val body = ByteArray(length).also { var n = 0; while (n < length) { val r = inp.read(it, n, length - n); if (r < 0) break; n += r } }.toString(Charsets.UTF_8)
                    val f = body.split('&').mapNotNull { kv -> kv.split('=', limit = 2).takeIf { it.size == 2 }?.let { URLDecoder.decode(it[0], "UTF-8") to URLDecoder.decode(it[1], "UTF-8") } }.toMap()
                    if (f["t"] == token && valid && !f["address"].isNullOrBlank()) {
                        used = true
                        onReceived(PhoneSetup(f["type"] ?: "xtream", f["name"].orEmpty().take(60), f["address"].orEmpty().trim().take(500), f["user"].orEmpty().trim().take(100), f["password"].orEmpty().take(200)))
                        send("200 OK", page("Sent to your TV", "Approve it on the TV with the remote. You can close this page."))
                    } else send("403 Forbidden", page("This link has expired", "Start again on the TV."))
                } else send("400 Bad Request", page("Not understood", ""))
            }
        }
    }

    private fun page(title: String, text: String) = "<!doctype html><meta name=viewport content='width=device-width,initial-scale=1'><body style='font-family:sans-serif;background:#080C14;color:#fff;padding:24px'><h2>$title</h2><p style='color:#B8CCD8'>$text</p>"
    private fun form() = """<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><title>StreamSetu</title>
<body style='font-family:sans-serif;background:#080C14;color:#fff;padding:20px;max-width:520px;margin:auto'>
<h2>Add a connection to your TV</h2><p style='color:#B8CCD8'>Type it here, then approve it on the TV. It is sent only to your TV, over your home network.</p>
<form method=post action=/submit><input type=hidden name=t value='$token'>
<style>input,select{width:100%;box-sizing:border-box;font-size:18px;padding:12px;margin:6px 0 14px;border-radius:8px;border:1px solid #29515E;background:#142735;color:#fff}button{font-size:18px;padding:14px;width:100%;border:0;border-radius:24px;background:#43DCE8;color:#04141A;font-weight:bold}</style>
Type<select name=type><option value=xtream>Xtream login</option><option value=m3u>M3U link</option></select>
Name (optional)<input name=name autocomplete=off>
Server address or playlist link<input name=address autocomplete=off autocapitalize=off required>
User name (Xtream)<input name=user autocomplete=off autocapitalize=off>
Password (Xtream)<input name=password type=password autocomplete=off>
<button>Send to TV</button></form>"""

    private fun localAddress(): InetAddress? = runCatching {
        NetworkInterface.getNetworkInterfaces().toList().filter { it.isUp && !it.isLoopback }.flatMap { it.inetAddresses.toList() }.firstOrNull { it is Inet4Address && it.isSiteLocalAddress }
    }.getOrNull()
}
