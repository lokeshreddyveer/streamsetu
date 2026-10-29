package app.streamsetu.tv.nav

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * Where the remote is in a screen that has a folder column (Movies, Series, Live TV): in the content, in the folders, or on its way to the main sidebar.
 *
 *     main sidebar --(Right / OK)--> folders --(Right / OK)--> content
 *     content --(Left at the first column / Back)--> folders --(Left / Back)--> main sidebar
 *
 * It holds only whether the folders are open and a counter that asks the screen to put the remote on the selected folder. The selected folder, the loaded pages, the scroll position
 * and the last card are the screen's own and are never touched here, so opening and closing the folders cannot lose them. Every move is safe to repeat.
 */
class FolderNav(startOpen: Boolean = false) {
    enum class Next { NOTHING, MAIN_SIDEBAR }

    var open by mutableStateOf(startOpen)
        private set
    /** Raised each time the remote should be put on the selected folder (once the column has its place on screen). */
    var focusTick by mutableIntStateOf(0)
        private set

    /** The page was chosen in the main sidebar, or the Folders button was pressed: show the column and focus the selected folder. */
    fun show() { open = true; focusTick++ }

    /** Back. From the content it shows the folders; from the folders it asks for the main sidebar. */
    fun back(): Next = if (open) { open = false; Next.MAIN_SIDEBAR } else { show(); Next.NOTHING }

    /** Left. In the folders it asks for the main sidebar; from the first column of the content (the screen decides that) it shows the folders. */
    fun left(): Next = back()

    /** A folder was chosen, or Right was pressed: the column goes away and the content takes the remote. */
    fun hide() { open = false }

    /** The library was switched: start again with the column closed. */
    fun reset() { open = false }
}
