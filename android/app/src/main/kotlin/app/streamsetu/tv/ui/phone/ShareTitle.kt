package app.streamsetu.tv.ui.phone

import android.content.Context
import android.content.Intent
import android.net.Uri

/** Opens the share sheet with a streamsetu:// link that starts the film, series or channel by name on a phone that has StreamSetu and the same title. */
fun shareTitle(context: Context, kind: String, title: String) {
    val link = Uri.Builder().scheme("streamsetu").authority("watch").appendQueryParameter(kind, title.take(120)).build().toString()
    val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_SUBJECT, title).putExtra(Intent.EXTRA_TEXT, "Open “$title” in StreamSetu\n$link")
    context.startActivity(Intent.createChooser(send, "Share link").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
}
