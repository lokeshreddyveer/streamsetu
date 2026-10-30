package app.streamsetu.tv.sports.personal

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import app.streamsetu.core.data.repo.ParentalControls
import app.streamsetu.core.sports.SportsEvent
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.SyncEntryPoint
import app.streamsetu.tv.sports.RealSportsAuthorization
import app.streamsetu.tv.sports.SportsGuideInputs
import dagger.hilt.android.EntryPointAccessors
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/**
 * Alarms for Sports reminders, set with the system's alarm service the way the programme reminders are: `setAndAllowWhileIdle`, which needs no exact-alarm permission. That also means the system may
 * hold an alarm back a little to save power (battery saver, deep sleep), so a reminder can arrive late; the in-app banner covers the time the app is open. Before Android 6 a plain `set` is used.
 * One alarm per reminder id: setting it again replaces it.
 */
class AlarmReminderScheduler(private val context: Context) : ReminderScheduler {
    private val am get() = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager

    /** The alarm's intent: an explicit component, the one action, and the reminder's id in its address (which is what makes it that reminder's own, since extras are not part of an intent's identity). No extras. */
    internal fun intentFor(id: String): Intent = Intent(context, SportsReminderReceiver::class.java).setAction(ACTION).setData(android.net.Uri.parse("$SCHEME://${android.net.Uri.encode(id)}"))

    private fun pending(id: String): PendingIntent = PendingIntent.getBroadcast(context, 0, intentFor(id), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

    override fun arm(id: String, atMs: Long) {
        val at = atMs.coerceAtLeast(System.currentTimeMillis() + 1000)
        runCatching { if (Build.VERSION.SDK_INT >= 23) am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending(id)) else am.set(AlarmManager.RTC_WAKEUP, at, pending(id)) }
    }

    override fun cancel(id: String) { runCatching { am.cancel(pending(id)) } }

    companion object {
        const val ACTION = "app.streamsetu.SPORTS_REMIND"
        const val SCHEME = "streamsetu-sports-reminder"

        /** The reminder an alarm is for, read only from the intent's action and address. Anything else (another action, another scheme, extras naming some other reminder) yields nothing. */
        fun idFrom(intent: Intent?): String? {
            if (intent?.action != ACTION) return null
            val uri = intent.data ?: return null
            if (uri.scheme != SCHEME) return null
            return uri.schemeSpecificPart?.removePrefix("//")?.let(android.net.Uri::decode)?.takeIf { it.isNotEmpty() && it.length <= 64 }
        }
    }
}

/**
 * The notification for a Sports reminder. The notification permission is asked for only by [requestPermission], which the first reminder calls; nothing asks at launch. A reminder with no title says
 * only that one is due. Tapping opens StreamSetu with the reminder's id, never a stream: the event is found and checked again inside the app.
 */
class AndroidReminderNotifier(private val context: Context, private val ask: () -> Unit) : ReminderNotifier {
    private val prefs = context.getSharedPreferences("sports-reminders", Context.MODE_PRIVATE)
    private val nm get() = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    override fun permission(): NotificationState = when {
        Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED ->
            if (prefs.getBoolean("asked", false)) NotificationState.DENIED else NotificationState.NOT_ASKED
        Build.VERSION.SDK_INT >= 24 && !nm.areNotificationsEnabled() -> NotificationState.DENIED
        Build.VERSION.SDK_INT >= 33 -> NotificationState.GRANTED
        else -> NotificationState.NOT_NEEDED
    }

    override fun requestPermission() { prefs.edit().putBoolean("asked", true).apply(); ask() }

    override fun post(id: String, title: String, startMs: Long): Boolean {
        if (permission() == NotificationState.DENIED) return false
        if (Build.VERSION.SDK_INT >= 26) nm.createNotificationChannel(NotificationChannel(CHANNEL, "Sports reminders", NotificationManager.IMPORTANCE_DEFAULT))
        val open = PendingIntent.getActivity(context, 0, openIntent(id), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, CHANNEL) else @Suppress("DEPRECATION") Notification.Builder(context)
        val time = java.text.DateFormat.getTimeInstance(java.text.DateFormat.SHORT).format(java.util.Date(startMs))
        b.setSmallIcon(android.R.drawable.ic_popup_reminder).setContentTitle(title).setContentText("Starts at $time").setContentIntent(open).setAutoCancel(true)
        return runCatching { nm.notify(id.hashCode(), b.build()) }.isSuccess
    }

    override fun cancel(id: String) { runCatching { nm.cancel(id.hashCode()) } }

    /** Opens StreamSetu for one reminder. The reminder's id is in the address (so each notification is its own); nothing else is carried, and the app reads nothing else. */
    internal fun openIntent(id: String): Intent = Intent(context, app.streamsetu.tv.MainActivity::class.java).setData(android.net.Uri.parse("$OPEN_SCHEME://${android.net.Uri.encode(id)}")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)

    companion object {
        const val CHANNEL = "sports_reminders"
        const val OPEN_SCHEME = "streamsetu-sports-open"

        /** The reminder a tap is for, from the address only. Whatever the intent carries as extras is ignored. */
        fun openIdFrom(intent: Intent?): String? {
            val uri = intent?.data ?: return null
            if (uri.scheme != OPEN_SCHEME) return null
            return uri.schemeSpecificPart?.removePrefix("//")?.let(android.net.Uri::decode)?.takeIf { it.isNotEmpty() && it.length <= 64 }
        }
    }
}

/** The app's services as the reminders use them. */
class RealReminderDeps(private val context: Context, c: AppContainer) : RealSportsAuthorization(c), ReminderDeps {
    override val activeProfile: StateFlow<String> get() = c.profiles.activeId
    override fun nowMs() = System.currentTimeMillis()
    override val scheduler: ReminderScheduler = AlarmReminderScheduler(context)
    override val notifier: ReminderNotifier = AndroidReminderNotifier(context) { c.askNotificationPermission?.invoke() }

    override suspend fun events(fromMs: Long, toMs: Long): List<SportsEvent> {
        val ctx = SportsGuideInputs.context(c.db, profileId, c.parental.hideAdult.value, c.folders.lockedIdsNow(), ParentalControls::isAdultName)
        return c.sportsService.events(fromMs, toMs, ctx)
    }
}

/** An alarm went off. The app may have been closed: the event is found afresh and checked again before anything is shown. */
class SportsReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (!app.streamsetu.tv.sports.SportsFeature.enabled) return                          // Sports is off: an alarm that still arrives does nothing and starts nothing
        val id = AlarmReminderScheduler.idFrom(intent) ?: return                            // only our own alarm, and only the reminder its address names
        val pending = goAsync()
        CoroutineScope(Dispatchers.IO).launch { runCatching { EntryPointAccessors.fromApplication(context.applicationContext, SyncEntryPoint::class.java).container().sportsReminders.fire(id) }; pending.finish() }
    }
}

/** After a restart, an app update or a time zone change the alarms are set again, for the active profile only. */
class SportsRescheduleReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (!app.streamsetu.tv.sports.SportsFeature.enabled) return
        if (intent.action != Intent.ACTION_BOOT_COMPLETED && intent.action != Intent.ACTION_MY_PACKAGE_REPLACED && intent.action != Intent.ACTION_TIMEZONE_CHANGED) return
        val pending = goAsync()
        CoroutineScope(Dispatchers.IO).launch { runCatching { EntryPointAccessors.fromApplication(context.applicationContext, SyncEntryPoint::class.java).container().sportsReminders.rescheduleAll() }; pending.finish() }
    }
}
