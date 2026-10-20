package app.streamsetu.tv.ui.components

import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Folder
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.core.model.ContentKind
import app.streamsetu.tv.AppContainer
import app.streamsetu.tv.ui.theme.Tokens

/**
 * Where a film or series sits: the folder it is in, as "In folder  ENGLISH | NETFLIX". Choosing it opens that folder. This is what tells the person where a title found by search
 * lives, so they can browse what is next to it.
 */
@Composable
fun FolderPath(c: AppContainer, kind: ContentKind, categoryId: String?, phone: Boolean, onOpen: (folderId: String) -> Unit) {
    if (categoryId == null) return
    val folders by remember(kind) { c.folders.folders(kind) }.collectAsState(emptyList())
    val folder = folders.firstOrNull { it.id == categoryId } ?: return
    val label: @Composable () -> Unit = {
        Row(Modifier.padding(horizontal = 12.dp, vertical = if (phone) 8.dp else 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Image(Icons.Filled.Folder, null, Modifier.size(if (phone) 16.dp else 18.dp), colorFilter = ColorFilter.tint(Tokens.accent))
            Label("In folder", if (phone) Tokens.caption else Tokens.small, Tokens.textSecondary)
            Label(folder.title, if (phone) Tokens.small else Tokens.row, Tokens.text, FontWeight.SemiBold, maxLines = 1)
        }
    }
    if (phone) Row(Modifier.clip(RoundedCornerShape(14.dp)).clickable { onOpen(folder.id) }) { label() }
    else Focusable({ onOpen(folder.id) }, Modifier, shape = RoundedCornerShape(50), container = Tokens.card, scaleOnFocus = 1.03f) { _ -> label() }
}
