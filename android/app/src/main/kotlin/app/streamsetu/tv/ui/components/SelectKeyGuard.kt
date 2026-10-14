package app.streamsetu.tv.ui.components

import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.type

/**
 * Keeps a menu that was opened by holding OK from being chosen by the same press. The menu is a window of its own, so the repeats of the held key and its release arrive in it:
 * the release would choose the first item and close the menu. Until OK has been let go of once (or has not been held for a moment), the menu ignores OK.
 * The menu's being open never depends on whether the finger stays on the button.
 */
class SelectKeyGuard(private val now: () -> Long = { System.currentTimeMillis() }, private val quietMs: Long = 400) {
    var armed = false; private set
    private var lastDown = now()

    /** True when this OK event is part of the opening press and must be swallowed. */
    fun swallow(down: Boolean): Boolean {
        if (armed) return false
        if (down) lastDown = now() else armed = true
        return true
    }

    /** Called every so often: OK has not been held for [quietMs], so the opening press is over. */
    fun tick() { if (!armed && now() - lastDown > quietMs) armed = true }

    companion object {
        fun isSelect(e: KeyEvent) = e.key == Key.DirectionCenter || e.key == Key.Enter || e.key == Key.NumPadEnter
        fun isDown(e: KeyEvent) = e.type == KeyEventType.KeyDown
    }
}
