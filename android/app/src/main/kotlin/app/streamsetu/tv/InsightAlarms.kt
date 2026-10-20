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
import java.util.Calendar

/**
 * Single notifications set a little ahead with the system's alarm service: the weekly digest on Sunday evening, and a reminder before the usual viewing time.
 * Each is written from the numbers as they were when the app last started, and set again each time it starts, so it is only as fresh as the last visit.
 * Everything stays on the device.
 */
object InsightAlarms {
    const val ACTION = "app.streamsetu.NOTICE"
    const val DIGEST = "digest"
    const val USUAL = "usual"
    private const val CHANNEL = "insights"

    /** The next Sunday at 18:00 after [now]. */
    fun nextSunday(now: Long = System.currentTimeMillis()): Long {
        val c = Calendar.getInstance().apply { timeInMillis = now; set(Calendar.HOUR_OF_DAY, 18); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0) }
        while (c.get(Calendar.DAY_OF_WEEK) != Calendar.SUNDAY || c.timeInMillis <= now) c.add(Calendar.DAY_OF_YEAR, 1)
        return c.timeInMillis
    }

    /** The next time ten minutes before [hour], after [now]. */
    fun nextBefore(hour: Int, now: Long = System.currentTimeMillis()): Long {
        val c = Calendar.getInstance().apply { timeInMillis = now; set(Calendar.HOUR_OF_DAY, (hour + 23) % 24); set(Calendar.MINUTE, 50); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0) }
        if (c.timeInMillis <= now) c.add(Calendar.DAY_OF_YEAR, 1)
        return c.timeInMillis
    }

    private fun pending(context: Context, id: String, title: String?, body: String?): PendingIntent {
        val i = Intent(context, NoticeReceiver::class.java).setAction(ACTION).setData(android.net.Uri.parse("streamsetu-notice://$id"))
        if (title != null) i.putExtra("id", id).putExtra("title", title).putExtra("body", body.orEmpty())
        return PendingIntent.getBroadcast(context, 0, i, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    fun arm(context: Context, id: String, atMs: Long, title: String, body: String) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pi = pending(context, id, title, body)
        if (Build.VERSION.SDK_INT >= 23) am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMs, pi) else am.set(AlarmManager.RTC_WAKEUP, atMs, pi)
    }

    fun cancel(context: Context, id: String) = (context.getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(pending(context, id, null, null))

    fun show(context: Context, id: String, title: String, body: String) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) nm.createNotificationChannel(NotificationChannel(CHANNEL, "Weekly summary and usual time", NotificationManager.IMPORTANCE_DEFAULT))
        val open = PendingIntent.getActivity(context, id.hashCode(), (context.packageManager.getLaunchIntentForPackage(context.packageName) ?: Intent()).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), PendingIntent.FLAG_IMMUTABLE)
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, CHANNEL) else @Suppress("DEPRECATION") Notification.Builder(context)
        b.setSmallIcon(android.R.drawable.ic_popup_reminder).setContentTitle(title).setContentText(body).setStyle(Notification.BigTextStyle().bigText(body)).setContentIntent(open).setAutoCancel(true)
        runCatching { nm.notify(id.hashCode(), b.build()) }
    }
}

class NoticeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != InsightAlarms.ACTION) return
        InsightAlarms.show(context, intent.getStringExtra("id") ?: return, intent.getStringExtra("title").orEmpty(), intent.getStringExtra("body").orEmpty())
    }
}
