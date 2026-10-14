package app.streamsetu.core.data.repo

import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.db.ChannelEntity
import app.streamsetu.core.data.db.ChannelPrefEntity
import kotlinx.coroutines.flow.Flow

/**
 * What the person changed about channels: hide one, give it another name, or tie it to another guide channel. These are kept in their own table, so a refresh of the
 * playlist (which replaces the channel rows) does not lose them; [applyAfterRefresh] puts them back. The provider's own data is never edited.
 */
class ChannelPrefs(private val db: AppDatabase) {
    val all: Flow<List<ChannelPrefEntity>> = db.extras().channelPrefs()

    private suspend fun update(id: String, change: (ChannelPrefEntity) -> ChannelPrefEntity) {
        val e = db.extras()
        val next = change(e.channelPref(id) ?: ChannelPrefEntity(id))
        if (!next.hidden && next.name == null && next.epgId == null) e.clearChannelPref(id) else e.putChannelPref(next)
    }

    suspend fun setHidden(id: String, hidden: Boolean) = update(id) { it.copy(hidden = hidden) }
    suspend fun setHiddenMany(ids: Collection<String>, hidden: Boolean) = ids.forEach { setHidden(it, hidden) }

    /** [name] null or blank goes back to the provider's name. [original] is the provider's name, to tell when nothing was really changed. */
    suspend fun rename(channel: ChannelEntity, name: String?) {
        val clean = name?.trim()?.takeIf { it.isNotEmpty() && it != channel.name }
        update(channel.id) { it.copy(name = clean) }
        db.extras().setChannelName(channel.id, clean ?: channel.name)
    }

    suspend fun mapGuide(channel: ChannelEntity, epgId: String?) {
        val clean = epgId?.trim()?.takeIf { it.isNotEmpty() }
        update(channel.id) { it.copy(epgId = clean) }
        db.extras().setChannelEpg(channel.id, clean ?: channel.epgId)
    }

    suspend fun reset(channel: ChannelEntity) { db.extras().clearChannelPref(channel.id) }

    /** Called after a playlist was read again: names and guide ids the person set are written back onto the new rows. */
    suspend fun applyAfterRefresh() {
        val e = db.extras()
        e.channelPrefsNow().forEach { p ->
            p.name?.let { e.setChannelName(p.channelId, it) }
            p.epgId?.let { e.setChannelEpg(p.channelId, it) }
        }
    }
}
