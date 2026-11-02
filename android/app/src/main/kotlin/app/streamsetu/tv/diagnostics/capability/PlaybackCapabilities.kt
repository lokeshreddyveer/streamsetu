package app.streamsetu.tv.diagnostics.capability

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** The profile or the reason there is none. */
sealed class CapabilityResult {
    data class Ready(val profile: PlaybackCapabilityProfile) : CapabilityResult()
    data class Failed(val reason: String) : CapabilityResult()
}

/**
 * Builds the profile once, off the main thread, and keeps it for the life of the process. It is read again only after [invalidate] (the display or the audio output changed) or when
 * the person asks for [refresh]. Nothing polls. A part that cannot be read becomes an empty part, so one failing device API never hides the others.
 */
class PlaybackCapabilities(
    private val sources: CapabilitySources, private val now: () -> Long = System::currentTimeMillis, private val dispatcher: CoroutineDispatcher = Dispatchers.Default,
) {
    companion object {
        @Volatile private var shared: PlaybackCapabilities? = null
        /** The one kept for the process. */
        fun of(context: android.content.Context): PlaybackCapabilities = shared ?: synchronized(this) { shared ?: PlaybackCapabilities(AndroidCapabilitySources(context)).also { shared = it } }
    }

    private val lock = Mutex()
    @Volatile private var cached: CapabilityResult.Ready? = null

    /** The profile now: the kept one, or one built right now. Returns [CapabilityResult.Failed] only when nothing at all could be read. */
    suspend fun get(refresh: Boolean = false): CapabilityResult = withContext(dispatcher) {
        lock.withLock {
            if (!refresh) cached?.let { return@withLock it }
            val built = build()
            if (built is CapabilityResult.Ready) cached = built
            built
        }
    }

    /** Forgets the kept profile; the next [get] reads again. Cheap and safe to call from a listener. */
    fun invalidate() { cached = null }

    private fun build(): CapabilityResult {
        val device = runCatching { sources.device() }.getOrNull() ?: return CapabilityResult.Failed("The device did not describe itself.")
        val decoders = runCatching { sources.decoders() }.getOrDefault(emptyList())
        val display = runCatching { sources.display() }.getOrNull() ?: DisplayFacts(null, emptyList(), Reported.UNKNOWN, Reported.UNKNOWN, Reported.UNKNOWN, Reported.UNKNOWN, null, null, null, "unavailable", 0, 0)
        val audio = runCatching { sources.audio() }.getOrDefault(AudioFacts(emptyList(), null))
        val memory = runCatching { sources.memory() }.getOrDefault(MemoryFacts(0, 0, false, 0, 0))
        return CapabilityResult.Ready(PlaybackCapabilityProfile(device, memory, display, audio, decoders, now()))
    }
}
