package app.streamsetu.tv.ui.screens.detail

import app.streamsetu.core.model.Episode
import app.streamsetu.core.model.WatchProgress

/**
 * Which episode to offer next, and whether earlier ones were skipped.
 *  - [forward]: the first episode after the furthest one finished.
 *  - [catchUp]: the earliest unfinished episode before that furthest one (only when something was skipped and is available now).
 *  - [gapBefore]: true when the forward episode does not follow the last finished one directly (an episode is missing), so nothing may autoplay across it.
 */
data class EpisodePlan(val forward: Episode?, val catchUp: Episode?, val gapBefore: Boolean, val inProgress: Episode?, val allFinished: Boolean) {
    companion object {
        fun of(episodes: List<Episode>, progress: Map<String, WatchProgress>): EpisodePlan {
            val ordered = episodes.sortedWith(compareBy({ it.season }, { it.number }))
            if (ordered.isEmpty()) return EpisodePlan(null, null, false, null, false)
            val done = { e: Episode -> progress[e.id]?.completed == true }
            val lastDone = ordered.indexOfLast(done)
            val inProgress = ordered.firstOrNull { e -> progress[e.id]?.let { !it.completed && it.positionMs > 30_000 } == true }
            val catchUp = if (lastDone > 0) ordered.subList(0, lastDone).firstOrNull { !done(it) } else null
            val forward = ordered.getOrNull(lastDone + 1)
            val gap = lastDone >= 0 && forward != null && !contiguous(ordered[lastDone], forward)
            return EpisodePlan(forward, catchUp, gap, inProgress, lastDone == ordered.lastIndex)
        }

        /** The next episode of the same season, or the first of the following season. */
        fun contiguous(a: Episode, b: Episode) = (b.season == a.season && b.number == a.number + 1) || (b.season == a.season + 1 && b.number <= 1)
    }
}
