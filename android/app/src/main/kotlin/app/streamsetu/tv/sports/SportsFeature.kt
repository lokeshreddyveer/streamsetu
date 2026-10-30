package app.streamsetu.tv.sports

import app.streamsetu.tv.BuildConfig

/**
 * The one switch for Sports in the app. Off by default: the Sports source, tests, tables and data all stay, but nothing in the released app reaches them (no sidebar entry, no Search results, no
 * deep link, no reminder or recording work, no guide processing for Sports). Turn it on for a build with `-PsportsEnabled=true`. Every place that would start Sports asks here; nothing inside Sports
 * does, so its behaviour is exactly what it was.
 */
object SportsFeature {
    @Volatile private var override: Boolean? = null

    val enabled: Boolean get() = override ?: BuildConfig.SPORTS_ENABLED

    /** For tests only: force the switch either way, or null to follow the build again. */
    fun forTest(on: Boolean?) { override = on }
}
