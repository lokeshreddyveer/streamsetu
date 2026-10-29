package app.streamsetu.tv.sports.multiview

import androidx.compose.runtime.Immutable
import app.streamsetu.core.sports.SportsEvent
import app.streamsetu.core.sports.SportsEventState
import app.streamsetu.tv.sports.RankInput
import app.streamsetu.tv.sports.SportsAuthorization
import app.streamsetu.tv.sports.SportsAuthorizer
import app.streamsetu.tv.sports.SportsFeedRanker
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * One chosen picture: an event and the feed to watch it on. The titles are for the screen only; they are held in memory, are never written anywhere and never reach a diagnostic. The temporary
 * event id is not a durable identity.
 */
@Immutable
data class MultiviewEntry(val eventId: String, val channelId: String, val sourceId: String, val eventTitle: String, val feedLabel: String)

/** One feed offered for choosing. */
@Immutable
data class FeedChoice(val channelId: String, val label: String, val unsupported: Boolean)

enum class AddRefusal { LIMIT, SAME_CHANNEL, SAME_EVENT, NOT_AVAILABLE, UNSUPPORTED_QUALITY, EVENT_GONE }

sealed interface SelectionResult {
    data class Done(val index: Int) : SelectionResult
    data class Refused(val reason: AddRefusal) : SelectionResult
}

@Immutable
data class SelectionState(val entries: List<MultiviewEntry> = emptyList(), val limit: Int = 2, val message: String? = null) {
    /** Two valid feeds are the least that make a Multi-View. */
    val canStart: Boolean get() = entries.size >= 2
}

/**
 * The list of feeds the person has picked for a Multi-View, before anything plays. Choosing, removing, replacing and reordering only change this list: no stream is started, no provider is
 * asked, and nothing runs from focus. Every entry is checked when it is added, and again before it is started.
 *
 *  - The same channel cannot be chosen twice.
 *  - Another feed of an event already chosen is refused unless the person says they want to compare feeds of the same event.
 *  - A channel that is restricted, hidden, gone, or in a quality this device is known not to decode is refused.
 *  - No more than the device's usable tile count.
 */
class SportsMultiviewSelection(
    private val auth: SportsAuthorization,
    private val capability: MultiviewCapability,
    private val rank: (String) -> RankInput,
) {
    private val lock = Any()
    private val _state = MutableStateFlow(SelectionState(limit = TileLimitPolicy.MAX))          // the device is asked when the Multiview is first used, not when this is made
    val state: StateFlow<SelectionState> = _state.asStateFlow()
    @Volatile private var lookup: (String) -> SportsEvent? = { null }
    @Volatile private var allEvents: () -> List<SportsEvent> = { emptyList() }

    /** Where the Sports Hub's loaded events can be found. */
    fun useEvents(all: () -> List<SportsEvent>) { allEvents = all; lookup = { id -> all().firstOrNull { it.id == id } } }

    /** The events a Multi-View can be built from right now: live, with at least one feed. */
    /** Every event the Sports screens hold (not only the live ones): the names that decide which team a follow means. */
    fun loadedEvents(): List<SportsEvent> = allEvents()

    fun liveEvents(nowMs: Long): List<SportsEvent> = allEvents().filter { it.state(nowMs) == SportsEventState.LIVE && it.feeds.isNotEmpty() }

    private suspend fun resolve(eventId: String, channelId: String?, others: List<MultiviewEntry>, allowSameEvent: Boolean): Pair<MultiviewEntry?, AddRefusal?> {
        val event = lookup(eventId) ?: return null to AddRefusal.EVENT_GONE
        val profile = auth.profileId
        val allowed = SportsAuthorizer.authorizedFeeds(auth, event, profile)
        if (auth.profileId != profile) return null to AddRefusal.NOT_AVAILABLE
        val ranked = SportsFeedRanker.rank(allowed.map { it.first }, rank(eventId))
        val chosen = (if (channelId == null) ranked.firstOrNull { !it.deprioritized } ?: ranked.firstOrNull() else ranked.firstOrNull { it.feed.channelId == channelId }) ?: return null to AddRefusal.NOT_AVAILABLE
        if (SportsFeedRanker.unsupported(chosen.feed, rank(eventId))) return null to AddRefusal.UNSUPPORTED_QUALITY
        if (others.any { it.channelId == chosen.feed.channelId }) return null to AddRefusal.SAME_CHANNEL
        if (!allowSameEvent && others.any { it.eventId == eventId }) return null to AddRefusal.SAME_EVENT
        val names = auth.sourceNames()
        return MultiviewEntry(eventId, chosen.feed.channelId, chosen.feed.sourceId, event.title, feedLabel(chosen.feed.channelName, names[chosen.feed.sourceId])) to null
    }

    private fun feedLabel(channel: String, source: String?) = if (source.isNullOrBlank()) channel else "$channel · $source"

    private fun refuse(r: AddRefusal): SelectionResult { _state.value = _state.value.copy(message = text(r)); return SelectionResult.Refused(r) }

    /** Adds an event with [channelId], or with its recommended feed when none is given. */
    suspend fun add(eventId: String, channelId: String? = null, allowSameEvent: Boolean = false): SelectionResult {
        val cur = _state.value
        if (cur.entries.size >= capability.usableLimit()) return refuse(AddRefusal.LIMIT)
        val (entry, why) = resolve(eventId, channelId, cur.entries, allowSameEvent)
        if (entry == null) return refuse(why ?: AddRefusal.NOT_AVAILABLE)
        synchronized(lock) {
            val now = _state.value
            if (now.entries.size >= capability.usableLimit()) return refuse(AddRefusal.LIMIT)
            if (now.entries.any { it.channelId == entry.channelId }) return refuse(AddRefusal.SAME_CHANNEL)
            _state.value = now.copy(entries = now.entries + entry, limit = capability.usableLimit(), message = null)
            return SelectionResult.Done(now.entries.size)
        }
    }

    /** Replaces the entry at [index] with another event (or another feed of the same event). */
    suspend fun replace(index: Int, eventId: String, channelId: String? = null, allowSameEvent: Boolean = false): SelectionResult {
        val cur = _state.value
        if (index !in cur.entries.indices) return refuse(AddRefusal.EVENT_GONE)
        val others = cur.entries.filterIndexed { i, _ -> i != index }
        val (entry, why) = resolve(eventId, channelId, others, allowSameEvent)
        if (entry == null) return refuse(why ?: AddRefusal.NOT_AVAILABLE)
        synchronized(lock) {
            val now = _state.value
            if (index !in now.entries.indices) return refuse(AddRefusal.EVENT_GONE)
            _state.value = now.copy(entries = now.entries.toMutableList().also { it[index] = entry }, message = null)
            return SelectionResult.Done(index)
        }
    }

    /** Another feed of the same event for the entry at [index]. */
    suspend fun changeFeed(index: Int, channelId: String): SelectionResult {
        val e = _state.value.entries.getOrNull(index) ?: return refuse(AddRefusal.EVENT_GONE)
        return replace(index, e.eventId, channelId, allowSameEvent = true)
    }

    /** The feeds of an event that may be chosen right now, best first, for the person to pick from. Read when the menu is opened, never from focus. */
    suspend fun feedChoices(eventId: String): List<FeedChoice> {
        val event = lookup(eventId) ?: return emptyList()
        val profile = auth.profileId
        val allowed = SportsAuthorizer.authorizedFeeds(auth, event, profile)
        val ranked = SportsFeedRanker.rank(allowed.map { it.first }, rank(eventId))
        val names = auth.sourceNames()
        return ranked.map { FeedChoice(it.feed.channelId, feedLabel(it.feed.channelName, names[it.feed.sourceId]), it.deprioritized) }
    }

    /** After tiles were removed (by hand, or because they are no longer allowed): the list keeps only the channels that still have a tile. */
    fun keepOnly(channelIds: Set<String>) { synchronized(lock) { val s = _state.value; val kept = s.entries.filter { it.channelId in channelIds }; if (kept.size != s.entries.size) _state.value = s.copy(entries = kept) } }

    fun remove(index: Int) { synchronized(lock) { val s = _state.value; if (index in s.entries.indices) _state.value = s.copy(entries = s.entries.filterIndexed { i, _ -> i != index }, message = null) } }

    /** Moves the entry at [index] earlier (negative) or later (positive). The first entry is the primary picture. */
    fun move(index: Int, delta: Int) {
        synchronized(lock) {
            val s = _state.value; val to = index + delta
            if (index !in s.entries.indices || to !in s.entries.indices) return
            val l = s.entries.toMutableList(); val e = l.removeAt(index); l.add(to, e)
            _state.value = s.copy(entries = l, message = null)
        }
    }

    fun clear() { synchronized(lock) { _state.value = SelectionState(limit = capability.usableLimit()) } }

    /** The selection is checked again against what is allowed now: a restricted, hidden or removed feed leaves it at once and nothing replaces it. */
    suspend fun revalidate() {
        val cur = _state.value; val profile = auth.profileId
        val keep = cur.entries.filter { e -> val ch = auth.channel(e.channelId); ch != null && ch.sourceId == e.sourceId && SportsAuthorizer.refusal(auth, ch, profile) == null }
        synchronized(lock) { _state.value = _state.value.let { now -> now.copy(entries = now.entries.filter { it in keep }, limit = capability.usableLimit()) } }
    }

    private fun text(r: AddRefusal) = when (r) {
        AddRefusal.LIMIT -> "This device can show ${capability.usableLimit()} views at once."
        AddRefusal.SAME_CHANNEL -> "That channel is already in the Multi-View."
        AddRefusal.SAME_EVENT -> "That event is already in the Multi-View. Choose to compare feeds of the same event to add another."
        AddRefusal.NOT_AVAILABLE -> "That feed is not available."
        AddRefusal.UNSUPPORTED_QUALITY -> "This device cannot show that quality."
        AddRefusal.EVENT_GONE -> "That event is no longer listed."
    }
}
