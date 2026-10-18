package app.streamsetu.tv

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import app.streamsetu.core.model.ContentKind
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/** The home-screen widget: what you were watching and how much is left. Tapping it opens the app. */
class ContinueWidget : AppWidgetProvider() {
    private data class Row(val title: String, val detail: String)

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val pending = goAsync()
        CoroutineScope(Dispatchers.IO).launch {
            try {
                val rows = runCatching { rows(context) }.getOrDefault(emptyList())
                ids.forEach { manager.updateAppWidget(it, views(context, rows)) }
            } finally { pending.finish() }
        }
    }

    private suspend fun rows(context: Context): List<Row> {
        val c = (context.applicationContext as StreamSetuApp).container
        val out = ArrayList<Row>(); val seenSeries = HashSet<String>()
        for (p in c.user.continueWatching(8).first()) {
            val left = ((p.durationMs - p.positionMs) / 60_000).toInt().coerceAtLeast(1)
            val detail = if (left >= 60) "${left / 60} h ${left % 60} min left" else "$left min left"
            when (p.kind) {
                ContentKind.MOVIE -> c.catalog.movie(p.itemId)?.let { out += Row(it.title, detail) }
                ContentKind.EPISODE -> c.catalog.episode(p.itemId)?.let { e ->
                    val series = c.catalog.series(e.seriesId)
                    if (series != null && seenSeries.add(series.id)) out += Row(series.title, "S${e.season} E${e.number}  ·  $detail")
                }
                else -> {}
            }
            if (out.size == 3) break
        }
        return out
    }

    private fun views(context: Context, rows: List<Row>): RemoteViews {
        val v = RemoteViews(context.packageName, R.layout.widget_continue)
        val titles = intArrayOf(R.id.row1_title, R.id.row2_title, R.id.row3_title)
        val details = intArrayOf(R.id.row1_detail, R.id.row2_detail, R.id.row3_detail)
        for (i in 0..2) {
            val row = rows.getOrNull(i)
            val text = row?.title ?: if (i == 0) context.getString(R.string.widget_continue_empty) else ""
            v.setTextViewText(titles[i], text); v.setTextViewText(details[i], row?.detail.orEmpty())
            v.setViewVisibility(titles[i], if (text.isEmpty()) android.view.View.GONE else android.view.View.VISIBLE)
            v.setViewVisibility(details[i], if (row == null) android.view.View.GONE else android.view.View.VISIBLE)
        }
        val open = PendingIntent.getActivity(context, 0, Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        v.setOnClickPendingIntent(R.id.widget_root, open)
        return v
    }

    companion object {
        /** Redraws every copy of the widget now, for when something was watched (the system only refreshes it every half hour). */
        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, ContinueWidget::class.java))
            if (ids.isNotEmpty()) context.sendBroadcast(Intent(context, ContinueWidget::class.java).setAction(AppWidgetManager.ACTION_APPWIDGET_UPDATE).putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids))
        }
    }
}
