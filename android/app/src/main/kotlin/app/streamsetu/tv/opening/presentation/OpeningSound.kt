package app.streamsetu.tv.opening.presentation

import app.streamsetu.tv.opening.domain.OpeningVariant

/**
 * Where the opening's sound will plug in (a warm hum, a soft power-on, one hit on the play button's press-in). It is off: there are no sound files yet. When they exist, they
 * play only when the Opening setting is not Off, follow the system volume and the silent switch, and stop at once on a skip.
 */
object OpeningSound {
    /** Stays false until the sound files are added to the app. */
    const val available = false

    /** The opening started: [variant] decides which cut of the sound would play. */
    fun start(variant: OpeningVariant) { if (!available) return }

    /** The opening was skipped or ended: any sound stops at once. */
    fun stop() { if (!available) return }
}
