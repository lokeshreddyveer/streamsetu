package app.streamsetu.tv.ui.components

import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import app.streamsetu.tv.AppContainer

/**
 * Shows the picture of whichever engine is playing. The engine's view can sit in one place at a time, so the preview in Live TV and the fullscreen player
 * hand it to each other: whoever is [active] takes it. The stream itself is never restarted by this.
 */
@Composable
fun EngineSurface(c: AppContainer, modifier: Modifier = Modifier, active: Boolean = true) {
    val engine by c.playback.engine.collectAsState()
    val aspect by c.playback.aspect.collectAsState()
    AndroidView(
        factory = { FrameLayout(it) },
        modifier = modifier,
        update = { frame ->
            val e = engine
            if (active && e != null) {
                val view = e.view(frame.context)
                if (view.parent !== frame) {
                    (view.parent as? ViewGroup)?.removeView(view)
                    frame.removeAllViews()
                    frame.addView(view, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
                    e.setAspect(aspect)
                    app.streamsetu.tv.trace.SSTrace.v { "surface attached now=${android.os.SystemClock.uptimeMillis()}" }
                }
            } else if (!active) frame.removeAllViews()
        },
        onRelease = { it.removeAllViews() },
    )
}
