package app.streamsetu.tv.sync

import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.db.Profile
import app.streamsetu.core.data.db.Profiles
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

enum class SwitchResult { Switched, NeedsPin, WrongPin, Failed }

/**
 * Profiles: people who share one device and one playlist, each with their own favorites, collections, history and resume points (see [Profiles]). Entering an adult profile that
 * has a PIN needs it, and leaving a kids profile needs that profile's PIN. Sync on this network carries the first profile only, so it pauses while another is in use.
 */
class ProfileService(private val db: AppDatabase, private val onSwitched: (Profile) -> Unit) {
    private val raw get() = db.openHelper.writableDatabase
    private val _profiles = MutableStateFlow<List<Profile>>(emptyList())
    private val _active = MutableStateFlow(Profiles.MAIN)
    val profiles: StateFlow<List<Profile>> = _profiles.asStateFlow()
    val activeId: StateFlow<String> = _active.asStateFlow()

    val active: Profile get() = _profiles.value.firstOrNull { it.id == _active.value } ?: Profile(Profiles.MAIN, "Me", false, false, 0)
    val isShared: Boolean get() = _profiles.value.size > 1
    val isMainActive: Boolean get() = _active.value == Profiles.MAIN
    val leavingNeedsPin: Boolean get() = active.kids

    fun reload() {
        Profiles.create(raw)
        _profiles.value = Profiles.list(raw)
        _active.value = Profiles.active(raw).takeIf { id -> _profiles.value.any { it.id == id } } ?: Profiles.MAIN
    }

    fun add(name: String, kids: Boolean, pin: String?): Profile? = Profiles.add(raw, name, kids, pin).also { reload() }
    fun rename(id: String, name: String) { Profiles.rename(raw, id, name); reload() }
    fun remove(id: String): Boolean = Profiles.remove(raw, id).also { reload() }

    /** The profile whose PIN is asked to switch to [target]: the kids profile in use (to leave it), else the target itself. Null when no PIN is needed. */
    fun pinOwnerFor(target: String): String? {
        val t = _profiles.value.firstOrNull { it.id == target } ?: return null
        return if (active.kids) active.id else if (!t.kids && t.hasPin) t.id else null
    }
    fun checkPin(id: String, pin: String) = Profiles.checkPin(raw, id, pin)

    fun switchTo(id: String, pin: String? = null): SwitchResult {
        if (id == _active.value) return SwitchResult.Switched
        val target = _profiles.value.firstOrNull { it.id == id } ?: return SwitchResult.Switched
        if (active.kids || (!target.kids && target.hasPin)) {
            val needed = if (active.kids) active.id else target.id
            if (pin == null) return SwitchResult.NeedsPin
            if (!Profiles.checkPin(raw, needed, pin)) return SwitchResult.WrongPin
        }
        val from = _active.value
        return try {
            Profiles.swap(raw, from, id)
            db.invalidationTracker.refreshVersionsAsync()
            reload(); onSwitched(active); SwitchResult.Switched
        } catch (e: Exception) { SwitchResult.Failed }
    }
}
