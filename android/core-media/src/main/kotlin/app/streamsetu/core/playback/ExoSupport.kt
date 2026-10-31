package app.streamsetu.core.playback

import androidx.media3.common.C
import androidx.media3.common.Tracks

/**
 * Whether ExoPlayer can really play a file: its picture and its sound each need one track this device decodes in full. A film in a Matroska file
 * starts in ExoPlayer (which hands frames straight to the screen); a file it cannot play in full goes to MPV, instead of starting without sound or picture.
 */
object ExoSupport {
    /** "video" or "audio" when the file has that kind of track and none of them is playable here; null when ExoPlayer can play it, or when the tracks are not known yet. */
    fun unplayable(tracks: Tracks): String? {
        if (tracks.groups.isEmpty()) return null
        for ((type, name) in listOf(C.TRACK_TYPE_VIDEO to "video", C.TRACK_TYPE_AUDIO to "audio")) {
            if (tracks.containsType(type) && !tracks.isTypeSupported(type, false)) return name
        }
        return null
    }
}
