package app.streamsetu.tv.diagnostics.capability

import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector

/**
 * The one place this package touches Media3's own decoder choice, which is marked unstable. It only asks which decoder Media3's default selector would put first for a video type,
 * so the Diagnostics page can show it beside the advice. It never builds a player, and a failure is just "no answer".
 */
object Media3DecoderAdapter {
    @OptIn(UnstableApi::class)
    fun preferred(mime: String, secure: Boolean): String? = runCatching { MediaCodecSelector.DEFAULT.getDecoderInfos(mime, secure, false).firstOrNull()?.name }.getOrNull()
}
