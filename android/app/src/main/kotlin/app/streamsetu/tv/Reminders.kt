package app.streamsetu.tv

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import app.streamsetu.core.data.db.ReminderEntity
import app.streamsetu.core.model.Channel
import app.streamsetu.core.model.EpgProgram
import dagger.hilt.android.EntryPointAccessors
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * Reminders for programmes that have not started: a notification a minute before the start, which opens the channel. Alarms are set with the system's alarm service
 * (so they fire with the app closed) and set again after the phone restarts. Everything stays on the device.
 */
object Reminders {
    const val LEAD_MS = 60_000L
    private const val CHANNEL = "reminders"
    const val ACTION = "app.streamsetu.REMIND"

    fun idOf(channelId: String, startMs: Long) = "$channelId@$startMs"

    /** False when the programme starts too soon (or already has) to remind about. */
    suspend fun schedule(c: AppContainer, context: Context, ch: Channel, p: EpgProgram): Boolean {
        if (p.startMs - LEAD_MS <= System.currentTimeMillis()) return false
        val r = ReminderEntity(idOf(ch.id, p.startMs), ch.id, ch.name, p.title, p.startMs)
        c.db.extras().putReminder(r)
        arm(context, r)
        return true
    }

    suspend fun cancel(c: AppContainer, context: Context, id: String) {
        c.db.extras().deleteReminder(id)
        (context.getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(pending(context, id, null))
    }

    fun arm(context: Context, r: ReminderEntity) {
        val at = (r.startMs - LEAD_MS).coerceAtLeast(System.currentTimeMillis() + 1000)
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pi = pending(context, r.id, r)
        if (Build.VERSION.SDK_INT >= 23) am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi) else am.set(AlarmManager.RTC_WAKEUP, at, pi)
    }

    private fun pending(context: Context, id: String, r: ReminderEntity?): PendingIntent {
        val i = Intent(context, ReminderReceiver::class.java).setAction(ACTION).setData(android.net.Uri.parse("streamsetu-reminder://${android.net.Uri.encode(id)}"))
        if (r != null) i.putExtra("id", r.id).putExtra("channel", r.channelName).putExtra("title", r.title).putExtra("start", r.startMs)
        return PendingIntent.getBroadcast(context, 0, i, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    fun show(context: Context, id: String, channel: String, title: String, startMs: Long) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) nm.createNotificationChannel(NotificationChannel(CHANNEL, "Programme reminders", NotificationManager.IMPORTANCE_DEFAULT))
        val open = PendingIntent.getActivity(context, id.hashCode(), Intent(Intent.ACTION_VIEW, android.net.Uri.parse("streamsetu://play?kind=channel&q=" + android.net.Uri.encode(channel))).setPackage(context.packageName).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), PendingIntent.FLAG_IMMUTABLE)
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, CHANNEL) else @Suppress("DEPRECATION") Notification.Builder(context)
        b.setSmallIcon(android.R.drawable.ic_popup_reminder).setContentTitle(title).setContentText("Starting on $channel at " + java.text.DateFormat.getTimeInstance(java.text.DateFormat.SHORT).format(java.util.Date(startMs)))
            .setContentIntent(open).setAutoCancel(true)
        runCatching { nm.notify(id.hashCode(), b.build()) }
    }
}

/** An alarm went off: show the reminder and forget it. */
class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Reminders.ACTION) return
        val id = intent.getStringExtra("id") ?: return
        Reminders.show(context, id, intent.getStringExtra("channel").orEmpty(), intent.getStringExtra("title").orEmpty(), intent.getLongExtra("start", 0))
        val pending = goAsync()
        CoroutineScope(Dispatchers.IO).launch { runCatching { EntryPointAccessors.fromApplication(context.applicationContext, SyncEntryPoint::class.java).container().db.extras().deleteReminder(id) }; pending.finish() }
    }
}

/** After the phone restarts the alarms are gone; the ones still in the future are set again. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        val pending = goAsync()
        CoroutineScope(Dispatchers.IO).launch {
            runCatching {
                val db = EntryPointAccessors.fromApplication(context.applicationContext, SyncEntryPoint::class.java).container().db
                db.extras().pruneReminders(System.currentTimeMillis()); db.extras().remindersNow().forEach { Reminders.arm(context, it) }
            }
            pending.finish()
        }
    }
}
