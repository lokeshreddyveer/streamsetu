package app.streamsetu.tv.trace

import android.util.Log
import app.streamsetu.tv.BuildConfig

/**
 * The measurement hooks of the automated tests (frame and query logging, the Entry log of Movies and Series, artwork failures and the Projector Mode switch). They are in the real app so
 * there is one app to test and to ship, and they are off: nothing is written and nothing extra is measured unless the device was told `adb shell setprop log.tag.SSHOOKS VERBOSE`, which
 * only someone with adb can do (the app cannot set it). Read once, when the app starts; a test build has them on.
 */
object TestHooks {
    val on: Boolean = BuildConfig.FRAME_LOG || Log.isLoggable("SSHOOKS", Log.VERBOSE)
}
