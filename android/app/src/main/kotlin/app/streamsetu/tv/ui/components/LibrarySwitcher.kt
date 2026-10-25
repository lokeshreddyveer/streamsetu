package app.streamsetu.tv.ui.components

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.core.model.LibraryEntry
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.nav.Navigator
import app.streamsetu.tv.ui.theme.Tokens
import kotlinx.coroutines.launch

/**
 * The library you are in, as a small control at the top of a page. OK opens a compact list of the other libraries; choosing one opens it right there, on the same page (the page
 * reloads with the new library's titles; it does not go back to the start screen).
 */
@Composable
fun LibrarySwitcher(name: String, c: AppContainer, nav: Navigator, modifier: Modifier = Modifier) {
    val entries by c.library.entries.collectAsState(initial = emptyList())
    val scope = rememberCoroutineScope()
    var open by remember { mutableStateOf(false) }
    Focusable({ open = true }, modifier.testTag("library-switcher"), shape = RoundedCornerShape(Tokens.radius), container = Tokens.elevated, scaleOnFocus = 1.03f) { _ ->
        Row(Modifier.padding(horizontal = 14.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Image(Icons.Filled.Layers, null, Modifier.size(18.dp), colorFilter = ColorFilter.tint(Tokens.textSecondary))
            Label(name.ifBlank { "Library" }, Tokens.row, Tokens.text, FontWeight.SemiBold, maxLines = 1, modifier = Modifier.widthIn(max = 230.dp))
            Image(Icons.Filled.ArrowDropDown, null, Modifier.size(20.dp), colorFilter = ColorFilter.tint(Tokens.textSecondary))
        }
    }
    if (open) ContextMenu("Library", "Switch without leaving this page", buildList {
        entries.filter { it.usable }.forEach { e ->
            add(MenuAction(e.name + if (e.name == name) "   ✓" else "", if (e.kind == LibraryEntry.Kind.COMBINED) Icons.Filled.Layers else Icons.Filled.Dns) {
                if (e.name != name) scope.launch { c.library.open(e); nav.switchLibrary() }
            })
        }
        add(MenuAction("Manage Connections", Icons.Filled.Tune) { c.library.close(); nav.toChooser() })
    }, onClose = { open = false })
}
