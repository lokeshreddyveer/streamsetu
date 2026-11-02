package app.streamsetu.tv.ui.components

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.streamsetu.tv.ui.theme.Tokens

/** What a page shows instead of its content: it is loading, it is empty, or something failed. Never shows technical error text; an action (Retry, Add a connection) is optional. */
@Composable
fun TvStatusState(title: String, modifier: Modifier = Modifier, detail: String? = null, loading: Boolean = false, icon: ImageVector? = null, actionLabel: String? = null, onAction: (() -> Unit)? = null) {
    Column(modifier.fillMaxWidth().background(if (icon != null) Tokens.card else Color.Transparent, RoundedCornerShape(Tokens.radius)).padding(vertical = 12.dp, horizontal = if (icon != null) 16.dp else 0.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (loading) Spinner()
        if (icon != null) Image(icon, null, Modifier.size(28.dp), colorFilter = ColorFilter.tint(Tokens.warning))
        Label(title, Tokens.title, Tokens.text, FontWeight.SemiBold, maxLines = 2)
        if (!detail.isNullOrBlank()) Label(detail, Tokens.body, Tokens.textSecondary, maxLines = 3, modifier = Modifier.widthIn(max = 640.dp))
        if (actionLabel != null && onAction != null) TvButton(actionLabel, onAction)
    }
}
