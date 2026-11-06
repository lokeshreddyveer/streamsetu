package app.streamsetu.tv

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * True while a Kids profile is in use. Settings and Libraries (where all data is erased, profiles and connections are removed and the PIN can be changed) are then not reachable:
 * their entries are not shown and the navigator refuses to open them. The parent leaves the Kids profile with its PIN (switching profile asks for it).
 */
object KidsLock {
    var on by mutableStateOf(false)
}
