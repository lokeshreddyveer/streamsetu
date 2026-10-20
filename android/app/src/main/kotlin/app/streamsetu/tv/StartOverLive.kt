package app.streamsetu.tv

import app.streamsetu.core.data.repo.StartOver
import app.streamsetu.core.model.CatchUpPlayable
import app.streamsetu.core.model.Channel

/** The programme on now for [ch] when it could be offered from its beginning through the provider's catch-up, in the guide's own (stored) times; null when it cannot. */
suspend fun AppContainer.startOverFor(ch: Channel): app.streamsetu.core.data.db.EpgEntity? {
    if (ch.catchupDays <= 0) return null
    val epgId = epg.resolve(listOf(ch))[ch.id] ?: return null
    val shift = ui.epgOffsetMinutes.value * 60_000L
    val now = System.currentTimeMillis()
    val p = db.epg().window(listOf(epgId), now - shift, now - shift + 1).firstOrNull { it.startMs <= now - shift && it.endMs > now - shift } ?: return null
    return p.takeIf { StartOver.canOffer(p.startMs + shift, p.endMs + shift, ch.catchupDays, now) }
}

/** Plays the offered programme from its start. */
fun AppContainer.startOver(ch: Channel, p: app.streamsetu.core.data.db.EpgEntity) = play(CatchUpPlayable(ch, p.title, p.startMs, p.endMs))
