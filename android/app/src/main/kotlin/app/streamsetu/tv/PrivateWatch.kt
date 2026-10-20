package app.streamsetu.tv

/**
 * "Watch Privately": one play that leaves nothing behind. While it is on, nothing is saved about what is playing (no history, resume point, watched mark, statistics, last channel,
 * Android TV "Continue watching" entry or widget row) and the lock screen and notification show only "Private viewing". It is chosen per title, and it ends when playback stops;
 * the next episode, the next channel or another copy of the same title stays private.
 */
object PrivateWatch {
    @Volatile var on = false

    /** Whether the play that is starting is private: when asked for it is what was asked, otherwise it carries on as it is while something private is still playing. */
    fun resolve(asked: Boolean?, wasOn: Boolean, somethingPlaying: Boolean): Boolean = asked ?: (wasOn && somethingPlaying)

    /** What the lock screen, the notification and a paired device are told instead of the title. */
    const val TITLE = "Private viewing"
}
