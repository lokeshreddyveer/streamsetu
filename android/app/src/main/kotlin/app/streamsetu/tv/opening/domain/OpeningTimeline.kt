package app.streamsetu.tv.opening.domain

// The opening, "Tune In": the StreamSetu television is tuned in. A dot on its dark screen becomes the cream play button, and the teal ribbon draws on and binds the set
// ("setu" means "to bind"). The full 7.5 s story plays on the first ever launch, a 2.8 s cut on every other launch; it cannot be skipped. This file is the timeline only: what is on screen at any moment, worked out from the time alone (nothing is carried from one frame to the next),
// so any frame can be drawn, tested or frozen for review. The scene tables must match motion/specification/opening-motion.json at the root of the repository;
// OpeningSpecificationTest fails when they drift apart.

/** The scenes of the opening. Each variant uses its own list of them, in order. */
enum class Scene(val id: String) {
    DARK("dark"), GLOW_DOT("glowDot"), SWEEP_TWITCH("sweepTwitch"), WARM("warm"), ANTICIPATION("anticipation"), HERO("hero"), SHEEN("sheen"),
    WORDMARK("wordmark"), TAGLINE("tagline"), MATCH_CUT("matchCut"), WARM_WRAP("warmWrap"), LOCKUP("lockup"), HOLD("hold"), STILL("still"), FADE("fade"),
}

/** One scene's place in a variant, in milliseconds from the start. */
data class SceneSpan(val scene: Scene, val startMs: Int, val endMs: Int)

/**
 * Keyframes of one variant, in milliseconds (keyframesMs and keyframesMsFirstInstall in the specification). A null range is a beat the variant does not have.
 * [set]: the television rising out of the dark; [dot]: the dot appearing on the screen; [sweep]: the light crossing the silver; [twitch]: the antennas tuning; [snow]: faint
 * snow on the screen (brightest in its middle); [warm]: the screen warming to teal; [push]: the slow camera push (with a small breath back during [easeBack]);
 * [ribbonRear]/[ribbonFront]: the ribbon drawing on, behind the set and then in front of it; [swell]: the dot becoming the play button; [press]: the play button's press-in;
 * [glint]: the one glint (brightest in its middle); [sheen]: the satin light along the ribbon; [name]/[tagline]: the words; [cut]: the match-cut.
 */
data class Keyframes(
    val set: IntRange, val dot: IntRange, val sweep: IntRange, val twitch: IntRange, val snow: IntRange, val warm: IntRange, val push: IntRange, val easeBack: IntRange?,
    val ribbonRear: IntRange, val ribbonFront: IntRange, val swell: IntRange, val press: IntRange, val glint: IntRange, val sheen: IntRange,
    val name: IntRange, val tagline: IntRange, val cut: IntRange,
)

/** The ways the opening plays. [holdMs] is where the story ends: the last frame holds there until the app is ready, then [exitMs] of match-cut or fade. None can be skipped. */
enum class OpeningVariant(val id: String, val durationMs: Int, val scenes: List<SceneSpan>, val keys: Keyframes?) {
    /** The first ever launch of a new install: the full story, 7.5 s. */
    FIRST_INSTALL("firstInstall", 7500, listOf(
        SceneSpan(Scene.DARK, 0, 500), SceneSpan(Scene.GLOW_DOT, 500, 1500), SceneSpan(Scene.SWEEP_TWITCH, 1500, 2500), SceneSpan(Scene.WARM, 2500, 3500),
        SceneSpan(Scene.ANTICIPATION, 3500, 4500), SceneSpan(Scene.HERO, 4500, 5000), SceneSpan(Scene.SHEEN, 5000, 5500), SceneSpan(Scene.WORDMARK, 5500, 6200),
        SceneSpan(Scene.TAGLINE, 6200, 7000), SceneSpan(Scene.MATCH_CUT, 7000, 7500),
    ), Keyframes(
        set = 500..1500, dot = 500..900, sweep = 1500..2300, twitch = 1700..2200, snow = 1500..2500, warm = 2500..3500, push = 500..7000, easeBack = 3500..4400,
        ribbonRear = 2500..3500, ribbonFront = 3500..4500, swell = 3500..4500, press = 4500..4750, glint = 4675..4825, sheen = 5000..5500,
        name = 5500..6200, tagline = 6200..7000, cut = 7000..7500,
    )),
    /** Every other launch, including the first after an update (then What's New): one short cut, 2.8 s. */
    STANDARD("standard", 2800, listOf(
        SceneSpan(Scene.DARK, 0, 200), SceneSpan(Scene.GLOW_DOT, 200, 700), SceneSpan(Scene.SWEEP_TWITCH, 700, 1200), SceneSpan(Scene.WARM_WRAP, 1200, 1900),
        SceneSpan(Scene.HERO, 1900, 2150), SceneSpan(Scene.LOCKUP, 2150, 2500), SceneSpan(Scene.HOLD, 2500, 2650), SceneSpan(Scene.MATCH_CUT, 2650, 2800),
    ), Keyframes(
        set = 200..900, dot = 200..450, sweep = 700..1150, twitch = 850..1100, snow = 750..1250, warm = 1100..1700, push = 200..2650, easeBack = null,
        ribbonRear = 1150..1600, ribbonFront = 1400..1850, swell = 1500..1900, press = 1900..2050, glint = 1925..2075, sheen = 2000..2400,
        name = 2150..2400, tagline = 2250..2500, cut = 2650..2800,
    )),
    /** Reduced motion: the finished mark with its name, still, then an opacity fade into the app. Nothing moves. */
    REDUCED("reducedMotion", 1400, listOf(SceneSpan(Scene.STILL, 0, 1000), SceneSpan(Scene.FADE, 1000, 1400)), null);

    /** Where the story ends: the last scene (the match-cut or the fade) is the exit. */
    val holdMs: Int get() = scenes.last().startMs
    val exitMs: Int get() = scenes.last().let { it.endMs - it.startMs }
}

/** Everything the renderer needs for one frame. Values are 0..1 unless said otherwise; a negative position means that light is not on screen. */
data class OpeningMotionState(
    /** The room's teal glow, and how much of the television can be seen. */
    val roomGlow: Float = 0f, val set: Float = 0f,
    /** The dot on the screen (0 none, 1 full), and how far it has become the play button. */
    val dot: Float = 0f, val swell: Float = 0f,
    /** The play button's press-in: 0 at rest, 1 at its deepest (about 2.5 % smaller). */
    val press: Float = 0f,
    val sweep: Float = -1f, val twitch: Float = 0f, val snow: Float = 0f, val warm: Float = 0f,
    /** Camera scale (1.0 = no push). */
    val camera: Float = 1f,
    val ribbonRear: Float = 0f, val ribbonFront: Float = 0f,
    val glint: Float = 0f, val sheen: Float = -1f,
    val name: Float = 0f, val nameTracking: Float = 0f, val tagline: Float = 0f,
) {
    companion object {
        /** The finished lockup: the mark, its name and the tagline, nothing moving. The reduced-motion still, and the frame held while the app gets ready. */
        val LOCKUP = OpeningMotionState(roomGlow = 1f, set = 1f, dot = 1f, swell = 1f, warm = 1f, ribbonRear = 1f, ribbonFront = 1f, name = 1f, tagline = 1f)
    }
}

object Easing {
    fun clamp(x: Float) = x.coerceIn(0f, 1f)
    fun easeOut(x: Float): Float { val t = clamp(x); return 1f - (1f - t) * (1f - t) * (1f - t) }
    fun easeIn(x: Float): Float { val t = clamp(x); return t * t * t }
    fun cubicInOut(x: Float): Float { val t = clamp(x); return if (t < 0.5f) 4f * t * t * t else 1f - (-2f * t + 2f).let { it * it * it } / 2f }
    fun smoothstep(x: Float): Float { val t = clamp(x); return t * t * (3f - 2f * t) }
    /** Slow at both ends: the camera push, the screen warming. */
    fun slowInOut(x: Float): Float { val t = clamp(x); return 0.5f - 0.5f * kotlin.math.cos(Math.PI.toFloat() * t) }
    /** 0 at both ends and 1 in the middle: an out-and-back movement. */
    fun bump(x: Float): Float { val t = clamp(x); return kotlin.math.sin(Math.PI.toFloat() * t) }
}

object OpeningTimeline {
    /** The camera push over the whole piece: 4 % (the specification allows 3 to 5 %). */
    const val PUSH = 0.04f
    private fun p(ms: Float, r: IntRange?) = if (r == null) 1f else Easing.clamp((ms - r.first) / (r.last - r.first).coerceAtLeast(1))
    private fun inside(ms: Float, r: IntRange?) = r != null && ms >= r.first && ms <= r.last

    /** The frame at [ms] from the start of [variant]. Pure: the same time always gives the same frame. Past [OpeningVariant.holdMs] it is the lockup. */
    fun state(variant: OpeningVariant, ms: Float): OpeningMotionState {
        val k = variant.keys ?: return OpeningMotionState.LOCKUP
        if (ms >= variant.holdMs) return OpeningMotionState.LOCKUP.copy(camera = 1f + PUSH)          // the story ends pushed in; it holds there
        val swell = Easing.easeOut(p(ms, k.swell))
        // The push grows slowly across the piece (6 % in all), with a small breath back during the anticipation.
        val push = PUSH * Easing.slowInOut(p(ms, k.push)) - (k.easeBack?.let { 0.015f * Easing.bump(p(ms, it)) } ?: 0f)
        return OpeningMotionState(
            roomGlow = Easing.easeOut(p(ms, k.set)),
            // Out of the dark: a silhouette that is just readable, then the full set as the screen warms.
            set = Easing.slowInOut(p(ms, k.set)) * (0.5f + 0.5f * Easing.slowInOut(p(ms, k.warm))),
            dot = Easing.easeOut(p(ms, k.dot)),
            swell = swell,
            press = if (inside(ms, k.press)) Easing.bump(p(ms, k.press)) else 0f,
            sweep = if (inside(ms, k.sweep)) Easing.cubicInOut(p(ms, k.sweep)) else -1f,
            twitch = if (inside(ms, k.twitch)) twitchAt(p(ms, k.twitch)) else 0f,
            snow = if (inside(ms, k.snow)) 0.12f * Easing.bump(p(ms, k.snow)) else 0f,
            warm = Easing.slowInOut(p(ms, k.warm)),
            camera = 1f + push,
            ribbonRear = Easing.cubicInOut(p(ms, k.ribbonRear)), ribbonFront = Easing.cubicInOut(p(ms, k.ribbonFront)),
            glint = if (inside(ms, k.glint)) Easing.bump(p(ms, k.glint)) else 0f,
            sheen = if (inside(ms, k.sheen)) Easing.slowInOut(p(ms, k.sheen)) else -1f,
            name = Easing.easeOut(p(ms, k.name)), nameTracking = 1f - Easing.easeOut(p(ms, k.name)),
            tagline = Easing.easeOut(p(ms, k.tagline)),
        )
    }

    /** The antennas tuning once: a quick turn, a small overshoot back and a settle over a few frames. A signed fraction of the full turn. */
    private fun twitchAt(t: Float): Float = when {
        t < 0.3f -> Easing.easeOut(t / 0.3f)
        t < 0.6f -> 1f - 1.15f * Easing.cubicInOut((t - 0.3f) / 0.3f)
        else -> -0.15f * (1f - Easing.smoothstep((t - 0.6f) / 0.4f))
    }

    /** The scene playing at [ms], or null past the end. */
    fun sceneAt(variant: OpeningVariant, ms: Int): Scene? = variant.scenes.firstOrNull { ms >= it.startMs && ms < it.endMs }?.scene
}
