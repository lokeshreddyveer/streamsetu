package app.streamsetu.tv.ui.phone

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.tv.ui.components.Label
import app.streamsetu.tv.ui.theme.Tokens

data class SheetItem(val label: String, val icon: ImageVector? = null, val selected: Boolean = false, val detail: String? = null, val enabled: Boolean = true, val onClick: () -> Unit)

/** A sheet that slides up from the bottom: a title and a list of things to tap. Tapping outside it, or Back, closes it. */
@Composable
fun Sheet(title: String, items: List<SheetItem>, onClose: () -> Unit, subtitle: String? = null) {
    var shown by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { shown = true }
    BackHandler(enabled = true) { onClose() }
    Box(Modifier.fillMaxSize()) {
        AnimatedVisibility(shown, enter = fadeIn(), exit = fadeOut()) {
            Box(Modifier.fillMaxSize().background(Color(0x99000000)).clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onClose))
        }
        AnimatedVisibility(shown, Modifier.align(Alignment.BottomCenter), enter = slideInVertically { it / 2 } + fadeIn(), exit = slideOutVertically { it / 2 } + fadeOut()) {
            Column(
                Modifier.fillMaxWidth().widthIn(max = 640.dp).background(Color(0xFF141416), RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp))
                    .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {}.windowInsetsPadding(WindowInsets.navigationBars).padding(top = 8.dp, bottom = 8.dp),
            ) {
                Box(Modifier.align(Alignment.CenterHorizontally).width(36.dp).height(4.dp).background(Color(0x40FFFFFF), RoundedCornerShape(2.dp)))
                Column(Modifier.padding(horizontal = 20.dp, vertical = 12.dp)) {
                    Label(title, Ph.heading, Tokens.text, FontWeight.SemiBold)
                    if (subtitle != null) Label(subtitle, Ph.small, Tokens.textSecondary, modifier = Modifier.padding(top = 2.dp))
                }
                LazyColumn(Modifier.heightIn(max = 460.dp)) {
                    items(items) { it ->
                        Row(
                            Modifier.fillMaxWidth().then(if (it.enabled) Modifier.clickable { it.onClick(); onClose() } else Modifier).padding(horizontal = 20.dp, vertical = 12.dp),
                            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp),
                        ) {
                            if (it.icon != null) Icon(it.icon, if (it.enabled) Tokens.textSecondary else Tokens.textTertiary, 22.dp)
                            Column(Modifier.weight(1f)) {
                                Label(it.label, Ph.body, if (it.enabled) Tokens.text else Tokens.textTertiary, if (it.selected) FontWeight.SemiBold else FontWeight.Normal)
                                if (it.detail != null) Label(it.detail, Ph.caption, Tokens.textTertiary)
                            }
                            if (it.selected) Icon(Icons.Filled.Check, Tokens.accent, 20.dp)
                        }
                    }
                }
            }
        }
    }
}
