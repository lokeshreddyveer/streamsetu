package app.streamsetu.tv.sync

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.sync.lan.LanCrypto
import app.streamsetu.core.sync.lan.LanDataAdapter
import app.streamsetu.core.sync.lan.LanLink
import app.streamsetu.core.sync.lan.LanOutcome
import app.streamsetu.core.sync.lan.LanPeer
import app.streamsetu.core.sync.lan.LanProtocol
import app.streamsetu.core.sync.lan.LanTrust
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/** A TCP socket that sends and receives whole frames: 4 bytes (big endian) with the length, then the body, at most 8 MiB, as in docs/WIFI-SYNC.md. */
class SocketLink(private val socket: Socket) : LanLink {
    private val input = DataInputStream(socket.getInputStream().buffered())
    private val output = DataOutputStream(socket.getOutputStream().buffered())
    override fun send(frame: ByteArray) { require(frame.size <= MAX); output.writeInt(frame.size); output.write(frame); output.flush() }
    override fun receive(): ByteArray {
        val n = input.readInt()
        require(n in 0..MAX) { "frame too large" }
        return ByteArray(n).also { input.readFully(it) }
    }
    fun close() = runCatching { socket.close() }
    companion object { const val MAX = 8 shl 20 }
}

/** The devices this one has been paired with, kept in preferences (public keys and names only). */
class PrefsTrust(private val context: Context) : LanTrust {
    private val prefs get() = context.getSharedPreferences("lan", Context.MODE_PRIVATE)
    private val lock = Any()

    fun all(): List<LanPeer> = synchronized(lock) {
        runCatching {
            val a = JSONArray(prefs.getString("trusted", "[]"))
            (0 until a.length()).map { val o = a.getJSONObject(it); LanPeer(o.getString("id"), o.getString("name"), android.util.Base64.decode(o.getString("pub"), android.util.Base64.NO_WRAP)) }
        }.getOrDefault(emptyList())
    }
    override fun find(publicX963: ByteArray): LanPeer? = all().firstOrNull { it.publicX963.contentEquals(publicX963) }
    override fun add(peer: LanPeer) = save(all().filter { it.id != peer.id } + peer)
    fun remove(id: String) = save(all().filter { it.id != id })
    private fun save(list: List<LanPeer>) = synchronized(lock) {
        val a = JSONArray(); list.forEach { a.put(JSONObject().put("id", it.id).put("name", it.name).put("pub", android.util.Base64.encodeToString(it.publicX963, android.util.Base64.NO_WRAP))) }
        prefs.edit().putString("trusted", a.toString()).apply()
    }
}

/**
 * Sync on this network: finds the person's other devices (`_streamsetu-sync._tcp`), pairs with them once (both people compare six digits), and then keeps favourites,
 * Watch Later, collections and resume points in step. The conversation itself is [LanProtocol].
 */
class LanSyncService(private val context: Context, private val scope: CoroutineScope, private val db: AppDatabase, private val onApplied: () -> Unit = {}) {
    data class Found(val id: String, val name: String, val host: InetAddress, val port: Int)
    class Prompt(val digits: String, val peerName: String, internal val answer: CompletableFuture<Boolean>)

    private val prefs get() = context.getSharedPreferences("lan", Context.MODE_PRIVATE)
    private val trust = PrefsTrust(context)
    private val _enabled = MutableStateFlow(prefs.getBoolean("enabled", false))
    private val _found = MutableStateFlow<List<Found>>(emptyList())
    private val _trusted = MutableStateFlow(trust.all())
    private val _prompt = MutableStateFlow<Prompt?>(null)
    private val _status = MutableStateFlow("Off")
    private val _pairingOpen = MutableStateFlow(false)
    private val _message = MutableStateFlow<String?>(null)
    val enabled: StateFlow<Boolean> = _enabled.asStateFlow()
    val found: StateFlow<List<Found>> = _found.asStateFlow()
    val trusted: StateFlow<List<LanPeer>> = _trusted.asStateFlow()
    val prompt: StateFlow<Prompt?> = _prompt.asStateFlow()
    val status: StateFlow<String> = _status.asStateFlow()
    val pairingOpen: StateFlow<Boolean> = _pairingOpen.asStateFlow()
    val message: StateFlow<String?> = _message.asStateFlow()

    private val deviceName: String = (Build.MODEL ?: "Android").let { m -> if (Build.MANUFACTURER.isNullOrBlank() || m.startsWith(Build.MANUFACTURER, true)) m else "${Build.MANUFACTURER} $m" }
    private val identity: LanCrypto.Identity by lazy {
        val saved = prefs.getString("identity", null)?.split(":")
        if (saved != null && saved.size == 2) LanCrypto.Identity(android.util.Base64.decode(saved[0], android.util.Base64.NO_WRAP), android.util.Base64.decode(saved[1], android.util.Base64.NO_WRAP))
        else LanCrypto.newIdentity().also { prefs.edit().putString("identity", android.util.Base64.encodeToString(it.privatePkcs8, android.util.Base64.NO_WRAP) + ":" + android.util.Base64.encodeToString(it.publicX963, android.util.Base64.NO_WRAP)).apply() }
    }
    private val data by lazy { LanDataAdapter({ db.openHelper.writableDatabase }, { db.invalidationTracker.refreshVersionsAsync() }) }
    private val nsd get() = context.getSystemService(Context.NSD_SERVICE) as NsdManager

    private var server: ServerSocket? = null
    private var registration: NsdManager.RegistrationListener? = null
    private var discovery: NsdManager.DiscoveryListener? = null
    private var multicast: WifiManager.MulticastLock? = null
    private var loop: Job? = null
    private val resolving = Mutex()
    private val busy = java.util.Collections.synchronizedSet(HashSet<String>())

    /** Starts or stops to match the switch in Settings. */
    fun setEnabled(on: Boolean) {
        prefs.edit().putBoolean("enabled", on).apply()
        if (on == _enabled.value && (on == (server != null))) return
        _enabled.value = on
        if (on) start() else stop()
    }

    /** Called once the app has started. */
    fun startIfEnabled() { if (_enabled.value && server == null) start() }

    private fun protocol() = LanProtocol(identity, deviceName, trust, data, { _pairingOpen.value }, { digits, name -> ask(digits, name) })

    private fun start() {
        _status.value = "Looking for your devices…"
        runCatching {
            multicast = (context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager).createMulticastLock("streamsetu-sync").apply { setReferenceCounted(false); acquire() }
        }
        val s = runCatching { ServerSocket(0) }.getOrNull() ?: run { _status.value = "Could not start"; return }
        server = s
        scope.launch(Dispatchers.IO) {
            while (isActive && !s.isClosed) {
                val client = runCatching { s.accept() }.getOrNull() ?: break
                launch(Dispatchers.IO) { respond(client) }
            }
        }
        val info = NsdServiceInfo().apply {
            serviceName = identity.deviceId; serviceType = TYPE; port = s.localPort
            setAttribute("id", identity.deviceId); setAttribute("name", deviceName)
        }
        registration = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(i: NsdServiceInfo) {}
            override fun onRegistrationFailed(i: NsdServiceInfo, code: Int) {}
            override fun onServiceUnregistered(i: NsdServiceInfo) {}
            override fun onUnregistrationFailed(i: NsdServiceInfo, code: Int) {}
        }.also { runCatching { nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, it) } }
        discovery = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(t: String) {}
            override fun onDiscoveryStopped(t: String) {}
            override fun onStartDiscoveryFailed(t: String, code: Int) {}
            override fun onStopDiscoveryFailed(t: String, code: Int) {}
            override fun onServiceFound(i: NsdServiceInfo) { if (i.serviceName != identity.deviceId) scope.launch(Dispatchers.IO) { resolve(i) } }
            override fun onServiceLost(i: NsdServiceInfo) { _found.value = _found.value.filterNot { it.id == i.serviceName }; if (_found.value.isEmpty()) _status.value = "No other devices found" }
        }.also { runCatching { nsd.discoverServices(TYPE, NsdManager.PROTOCOL_DNS_SD, it) } }
        loop = scope.launch {
            while (isActive) { delay(90_000); syncNow() }
        }
    }

    private fun stop() {
        loop?.cancel(); loop = null
        runCatching { discovery?.let { nsd.stopServiceDiscovery(it) } }; discovery = null
        runCatching { registration?.let { nsd.unregisterService(it) } }; registration = null
        runCatching { server?.close() }; server = null
        runCatching { multicast?.release() }; multicast = null
        _found.value = emptyList(); _status.value = "Off"; _pairingOpen.value = false
        _prompt.value?.answer?.complete(false); _prompt.value = null
    }

    /** One resolve at a time: the system refuses a second while the first is running. */
    @Suppress("DEPRECATION")
    private suspend fun resolve(i: NsdServiceInfo) {
        resolving.lock()
        val done = CompletableFuture<NsdServiceInfo?>()
        try {
            nsd.resolveService(i, object : NsdManager.ResolveListener {
                override fun onResolveFailed(s: NsdServiceInfo, code: Int) { done.complete(null) }
                override fun onServiceResolved(s: NsdServiceInfo) { done.complete(s) }
            })
            val r = withContext(Dispatchers.IO) { runCatching { done.get(6, TimeUnit.SECONDS) }.getOrNull() } ?: return
            val id = r.attributes["id"]?.let { String(it) } ?: r.serviceName
            if (id == identity.deviceId || r.host == null) return
            val name = r.attributes["name"]?.let { String(it) } ?: "Device"
            val old = _found.value.map { it.id }.toSet()
            _found.value = _found.value.filterNot { it.id == id } + Found(id, name, r.host, r.port)
            if (id !in old && _trusted.value.any { it.id == id }) scope.launch { syncNow() }
        } finally { resolving.unlock() }
    }

    fun setPairing(open: Boolean) { _pairingOpen.value = open; _message.value = null }

    fun forget(peer: LanPeer) { trust.remove(peer.id); _trusted.value = trust.all() }

    /** Syncs with every paired device that is on the network now. */
    suspend fun syncNow() {
        if (!_enabled.value) return
        for (f in _found.value) if (_trusted.value.any { it.id == f.id }) run(f)
    }

    /** Starts pairing with a device found on the network (the person picked it in "Add a device"). */
    suspend fun pair(f: Found) = run(f)

    private suspend fun run(f: Found) {
        if (!busy.add(f.id)) return
        try {
            _status.value = "Syncing with ${f.name}…"
            val outcome = withContext(Dispatchers.IO) {
                val socket = Socket()
                try {
                    socket.connect(InetSocketAddress(f.host, f.port), 8000); socket.soTimeout = 300_000
                    protocol().runInitiator(SocketLink(socket))
                } catch (e: Exception) { LanOutcome.Failed(e.message ?: "failed") } finally { runCatching { socket.close() } }
            }
            finish(outcome, f.name)
        } finally { busy.remove(f.id) }
    }

    private fun respond(socket: Socket) {
        val link = SocketLink(socket)
        try {
            socket.soTimeout = 300_000
            finish(protocol().runResponder(link), null)
        } catch (e: Exception) { /* the other device went away */ } finally { link.close() }
    }

    private fun finish(outcome: LanOutcome, name: String?) {
        _trusted.value = trust.all()
        when (outcome) {
            is LanOutcome.Synced -> {
                _status.value = "Synced with ${outcome.peer.name}"
                if (outcome.paired) { _message.value = "${outcome.peer.name} is now paired."; _pairingOpen.value = false }
                if (outcome.received > 0) onApplied()
            }
            is LanOutcome.Refused -> {
                _status.value = if (outcome.reason == "not paired") "${name ?: "A device"} is not paired with this one" else "Pairing was not confirmed"
                if (_pairingOpen.value) _message.value = _status.value
            }
            is LanOutcome.Failed -> _status.value = "Sync with ${name ?: "a device"} did not finish"
        }
        _prompt.value?.answer?.complete(false); _prompt.value = null
    }

    /** Shows the six digits and waits (up to five minutes) for the person to say whether they match the other device's. */
    private fun ask(digits: String, peerName: String): Boolean {
        val answer = CompletableFuture<Boolean>()
        _prompt.value?.answer?.complete(false)
        _prompt.value = Prompt(digits, peerName, answer)
        return runCatching { answer.get(5, TimeUnit.MINUTES) }.getOrDefault(false)
    }

    fun answer(matches: Boolean) { _prompt.value?.answer?.complete(matches); _prompt.value = null }

    companion object { const val TYPE = "_streamsetu-sync._tcp." }
}
