package app.streamsetu.core.playback

import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build

/** Network checks that work from Android 5.1 (API 22) up: the newer calls are used only where they exist. */
object NetworkCompat {
    /** The device has a connection that reaches the internet. */
    @Suppress("DEPRECATION")
    fun isOnline(cm: ConnectivityManager): Boolean = runCatching {
        if (Build.VERSION.SDK_INT >= 23) {
            val n = cm.activeNetwork ?: return false
            cm.getNetworkCapabilities(n)?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
        } else cm.activeNetworkInfo?.isConnected == true
    }.getOrDefault(true)

    /** The connection is metered (mobile data, a hotspot). */
    fun isMetered(cm: ConnectivityManager): Boolean = runCatching { cm.isActiveNetworkMetered }.getOrDefault(true)

    /** Calls the callback as networks come and go; the "default network" form exists from Android 7, the request form before it. */
    fun register(cm: ConnectivityManager, callback: ConnectivityManager.NetworkCallback) {
        runCatching {
            if (Build.VERSION.SDK_INT >= 24) cm.registerDefaultNetworkCallback(callback)
            else cm.registerNetworkCallback(NetworkRequest.Builder().addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET).build(), callback)
        }
    }
}
