package app.streamsetu.tv

import android.content.Context
import android.os.Build
import app.streamsetu.core.data.repo.MaintenanceService
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Keeps a short, private note of a crash on this device (the kind of error, where it happened, the app version and device), with web addresses and secrets removed.
 * Nothing is sent anywhere; the notes show up in Settings, Diagnostics, and in an exported report.
 */
object CrashReporter {
    fun install(context: Context, versionName: String) {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { t, e ->
            runCatching {
                val dir = File(context.filesDir, "crashes").also { it.mkdirs() }
                val stamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())
                val text = buildString {
                    appendLine("StreamSetu $versionName  ·  ${Build.MANUFACTURER} ${Build.MODEL}  ·  Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})")
                    appendLine("Thread: ${t.name}")
                    appendLine(MaintenanceService.redact("${e.javaClass.name}: ${e.message.orEmpty()}"))
                    e.stackTrace.take(25).forEach { appendLine("  at $it") }
                    e.cause?.let { appendLine("Caused by " + MaintenanceService.redact("${it.javaClass.name}: ${it.message.orEmpty()}")) }
                }
                File(dir, "crash-$stamp.txt").writeText(text)
                dir.listFiles()?.sortedByDescending { it.lastModified() }?.drop(5)?.forEach { it.delete() }
            }
            previous?.uncaughtException(t, e)
        }
    }

    fun recent(context: Context): List<Pair<String, String>> =
        File(context.filesDir, "crashes").listFiles()?.sortedByDescending { it.lastModified() }?.take(3)?.map { it.name to runCatching { it.readText() }.getOrDefault("") }.orEmpty()
}
