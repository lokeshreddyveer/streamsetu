package app.streamsetu.tv.update

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import app.streamsetu.core.settings.AppSettings
import app.streamsetu.core.update.ReleaseAsset
import app.streamsetu.core.update.ReleaseInfo
import app.streamsetu.core.update.UpdateLogic
import app.streamsetu.tv.BuildConfig
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

sealed interface UpdateState {
    data object Idle : UpdateState
    data object Checking : UpdateState
    data class UpToDate(val checkedAt: Long) : UpdateState
    data class Available(val release: ReleaseInfo, val asset: ReleaseAsset) : UpdateState
    data class Downloading(val percent: Int) : UpdateState
    /** Downloaded and checked; the system installer is about to ask the person to confirm. */
    data class Ready(val file: File, val version: String) : UpdateState
    /** The device wants the person to allow this app to install apps first (Settings, one time). */
    data class NeedsPermission(val file: File, val version: String) : UpdateState
    data class Failed(val message: String) : UpdateState
}

/**
 * Looks for a newer StreamSetu release on GitHub, downloads it, checks it, and hands it to the system installer.
 *
 * What it will and will not do:
 *  - It asks `api.github.com` for the public release list. No account, no identifiers: the request carries the app's version in the User-Agent, like any HTTP client.
 *  - It never installs by itself. The system installer always asks the person to confirm.
 *  - A downloaded file is used only if its SHA-256 matches the one in the release notes AND it is signed with the same key as the installed app.
 *  - It runs only when asked, or once a day when the app opens and nothing is playing, so it never competes with a stream for the connection.
 * A build made for a store (-PselfUpdate=false) has all of this switched off.
 */
class UpdateManager(private val context: Context, private val settings: AppSettings, private val scope: CoroutineScope, private val isBusy: () -> Boolean = { false }) {
    val enabled: Boolean get() = BuildConfig.SELF_UPDATE

    private val _state = MutableStateFlow<UpdateState>(UpdateState.Idle)
    val state: StateFlow<UpdateState> = _state
    private val _prompt = MutableStateFlow(false)
    /** True when a newer version was found by the automatic check and the person has not yet been told about it. */
    val prompt: StateFlow<Boolean> = _prompt

    private val television: Boolean = context.packageManager.let { it.hasSystemFeature(PackageManager.FEATURE_LEANBACK) || it.hasSystemFeature("amazon.hardware.fire_tv") || it.hasSystemFeature(PackageManager.FEATURE_TELEVISION) }
    private val dir get() = File(context.cacheDir, "updates")

    /** Only a debuggable "selftest" build can pretend to be an older version, so the update path can be tried on a device. A release build ignores it. */
    private val debuggable = context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0
    private fun fakeVersion(): String? = if (debuggable) context.getSharedPreferences("settings", Context.MODE_PRIVATE).getString("update.fake.version", null)?.takeIf { it.isNotBlank() } else null

    fun installedVersion(): String = fakeVersion() ?: runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull().orEmpty().ifBlank { "0" }
    @Suppress("DEPRECATION")
    private fun installedCode(): Long = if (fakeVersion() != null) 1L else runCatching { context.packageManager.getPackageInfo(context.packageName, 0).let { if (Build.VERSION.SDK_INT >= 28) it.longVersionCode else it.versionCode.toLong() } }.getOrDefault(0L)

    fun dismissPrompt(skipVersion: Boolean = false) {
        if (skipVersion) (_state.value as? UpdateState.Available)?.let { settings.skippedUpdate = it.release.version }
        _prompt.value = false
    }

    /** At app start: once a day, only if the setting is on and nothing is playing. A failure is silent. */
    fun checkIfDue() {
        if (!enabled || !settings.autoUpdateCheck.value || isBusy()) return
        if (System.currentTimeMillis() - settings.lastUpdateCheckAt < DAY_MS) return
        runCatching { dir.deleteRecursively() }       // a file left from an earlier update is no longer needed
        check(manual = false)
    }

    fun check(manual: Boolean) {
        if (!enabled) return
        val s = _state.value
        if (s is UpdateState.Checking || s is UpdateState.Downloading) return
        _state.value = UpdateState.Checking
        scope.launch(Dispatchers.IO) {
            val result = runCatching { fetch() }
            android.util.Log.i("Update", "check manual=$manual installed=${installedVersion()} result=${result.map { r -> UpdateLogic.latest(r)?.version }.getOrElse { "error: ${it.message}" }}")
            settings.lastUpdateCheckAt = System.currentTimeMillis()
            result.onSuccess { releases ->
                val newest = UpdateLogic.latest(releases)
                val asset = newest?.takeIf { UpdateLogic.isNewer(it.version, installedVersion()) }?.let { UpdateLogic.pickAsset(it, television) }
                if (newest != null && asset != null) {
                    _state.value = UpdateState.Available(newest, asset)
                    if (!manual && newest.version != settings.skippedUpdate) _prompt.value = true
                } else _state.value = UpdateState.UpToDate(System.currentTimeMillis())
            }.onFailure {
                _state.value = if (manual) UpdateState.Failed("Could not check for updates. Check the connection and try again.") else UpdateState.Idle
            }
        }
    }

    private fun fetch(): List<ReleaseInfo> {
        val c = URL(RELEASES_URL).openConnection() as HttpURLConnection
        try {
            c.connectTimeout = 10_000; c.readTimeout = 15_000
            c.setRequestProperty("Accept", "application/vnd.github+json")
            c.setRequestProperty("User-Agent", "StreamSetu/${installedVersion()}")
            if (c.responseCode != 200) error("GitHub answered ${c.responseCode}")
            return UpdateLogic.parse(c.inputStream.bufferedReader().use { it.readText() })
        } finally { c.disconnect() }
    }

    /** Downloads the offered file, checks it, and opens the installer. */
    fun downloadAndInstall() {
        val offer = _state.value as? UpdateState.Available ?: return
        android.util.Log.i("Update", "download requested for ${offer.release.version}")
        _prompt.value = false
        _state.value = UpdateState.Downloading(0)
        scope.launch(Dispatchers.IO) {
            runCatching { download(offer) }
                .onSuccess { file ->
                    _state.value = UpdateState.Ready(file, offer.release.version)
                    withContext(Dispatchers.Main) { install(file, offer.release.version) }
                }
                .onFailure { _state.value = UpdateState.Failed(it.message ?: "The update could not be downloaded.") }
        }
    }

    private fun download(offer: UpdateState.Available): File {
        val expected = UpdateLogic.checksumFor(offer.release.notes, offer.asset.name) ?: error("This release has no checksum in its notes, so it was not installed.")
        if (!offer.asset.url.startsWith("https://")) error("The download address is not secure, so it was not installed.")
        dir.deleteRecursively(); dir.mkdirs()
        val file = File(dir, offer.asset.name)
        val digest = MessageDigest.getInstance("SHA-256")
        val c = URL(offer.asset.url).openConnection() as HttpURLConnection
        try {
            c.connectTimeout = 15_000; c.readTimeout = 30_000
            c.setRequestProperty("User-Agent", "StreamSetu/${installedVersion()}")
            if (c.responseCode != 200) error("The download failed (${c.responseCode}).")
            val total = c.contentLengthLong.takeIf { it > 0 } ?: offer.asset.size
            var done = 0L; var lastPercent = -1
            c.inputStream.use { input -> file.outputStream().use { out ->
                val buf = ByteArray(64 * 1024)
                while (true) {
                    val n = input.read(buf); if (n < 0) break
                    out.write(buf, 0, n); digest.update(buf, 0, n); done += n
                    if (total > 0) { val pct = (done * 100 / total).toInt().coerceIn(0, 100); if (pct != lastPercent) { lastPercent = pct; _state.value = UpdateState.Downloading(pct) } }
                }
            } }
        } catch (e: Exception) { file.delete(); throw e } finally { c.disconnect() }

        val actual = digest.digest().joinToString("") { "%02x".format(it) }
        android.util.Log.i("Update", "downloaded ${offer.asset.name} ${file.length()} bytes sha256=$actual expected=$expected")
        if (actual != expected) { file.delete(); error("The download did not match its checksum, so it was not installed.") }
        verifySigner(file)
        return file
    }

    /** The file must be signed with the same key as the installed app, and be a newer build. The installer would refuse a different key anyway; this says so in plain words first. */
    @Suppress("DEPRECATION")
    private fun verifySigner(file: File) {
        val pm = context.packageManager
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
        val archive = pm.getPackageArchiveInfo(file.absolutePath, flags) ?: run { file.delete(); error("The downloaded file is not a valid app.") }
        val installed = pm.getPackageInfo(context.packageName, flags)
        if (archive.packageName != context.packageName) { file.delete(); error("The downloaded file is for a different app, so it was not installed.") }
        if (certs(archive) != certs(installed) || certs(archive).isEmpty()) { file.delete(); error("The file is not signed with the same key as this app, so it was not installed.") }
        val code = if (Build.VERSION.SDK_INT >= 28) archive.longVersionCode else archive.versionCode.toLong()
        android.util.Log.i("Update", "signer ok; build $code vs installed ${installedCode()}")
        if (code <= installedCode()) { file.delete(); error("The downloaded build is not newer than the installed one.") }
    }

    @Suppress("DEPRECATION")
    private fun certs(info: android.content.pm.PackageInfo): Set<String> {
        val sigs = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.let { if (it.hasMultipleSigners()) it.apkContentsSigners else it.signingCertificateHistory } else info.signatures
        return sigs.orEmpty().map { MessageDigest.getInstance("SHA-256").digest(it.toByteArray()).joinToString("") { b -> "%02x".format(b) } }.toSet()
    }

    /** Called when the app comes back to the front: if the person has just allowed installing apps, the installer opens without another press. */
    fun resumeAfterPermission() {
        if (_state.value is UpdateState.NeedsPermission && (Build.VERSION.SDK_INT < 26 || context.packageManager.canRequestPackageInstalls())) install()
    }

    /** Opens the system installer, or the one-time setting that allows it. Call again after the setting is allowed. */
    fun install(file: File? = null, version: String? = null) {
        val ready = (_state.value as? UpdateState.Ready)?.let { it.file to it.version } ?: (_state.value as? UpdateState.NeedsPermission)?.let { it.file to it.version }
        val f = file ?: ready?.first ?: return
        val v = version ?: ready?.second ?: ""
        if (!f.exists()) { _state.value = UpdateState.Failed("The downloaded update is gone. Download it again."); return }
        if (Build.VERSION.SDK_INT >= 26 && !context.packageManager.canRequestPackageInstalls()) {
            _state.value = UpdateState.NeedsPermission(f, v)
            runCatching { context.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
            return
        }
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.updates", f)
        val intent = Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { context.startActivity(intent) }.onFailure { _state.value = UpdateState.Failed("This device has no installer for app files. Install the file yourself from the Releases page.") }
    }

    companion object {
        const val RELEASES_URL = "https://api.github.com/repos/lokeshreddyveer/streamsetu/releases?per_page=20"
        private const val DAY_MS = 24L * 60 * 60 * 1000
    }
}
