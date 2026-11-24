package app.streamsetu.tv.ui.components

import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusProperties
import androidx.compose.ui.focus.FocusPropertiesModifierNode
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.FocusRequesterModifierNode
import androidx.compose.ui.focus.restoreFocusedChild
import androidx.compose.ui.focus.saveFocusedChild
import androidx.compose.ui.layout.LocalPinnableContainer
import androidx.compose.ui.layout.PinnableContainer
import androidx.compose.ui.node.CompositionLocalConsumerModifierNode
import androidx.compose.ui.node.currentValueOf
import androidx.compose.ui.node.ModifierNodeElement

/**
 * `Modifier.focusRestorer()` with a pin that can be released safely.
 *
 * The stock restorer pins the card the remote last stood on, through the lazy list that card sits in (so it stays composed) and releases that pin when the row is
 * detached. When the row's cards change during a library import (cards leaving or swapping), the lazy list can already have
 * dropped the pin, and the second release stops the app with "Release should only be called once". This copy remembers the card and gives focus
 * back to it on entry (falling back to [onRestoreFailed]) like the stock one, but it pins the shelf the row sits in (which keeps
 * the row and its cards composed) and releases that pin at most once, ignoring a release the list no longer accepts.
 */
fun Modifier.safeFocusRestorer(onRestoreFailed: (() -> FocusRequester)? = null): Modifier = this then SafeFocusRestorerElement(onRestoreFailed)

private class SafeFocusRestorerElement(val onRestoreFailed: (() -> FocusRequester)?) : ModifierNodeElement<SafeFocusRestorerNode>() {
    override fun create() = SafeFocusRestorerNode(onRestoreFailed)
    override fun update(node: SafeFocusRestorerNode) { node.onRestoreFailed = onRestoreFailed }
    override fun equals(other: Any?) = other is SafeFocusRestorerElement && other.onRestoreFailed == onRestoreFailed
    override fun hashCode() = onRestoreFailed?.hashCode() ?: 0
}

@OptIn(ExperimentalComposeUiApi::class)
private class SafeFocusRestorerNode(var onRestoreFailed: (() -> FocusRequester)?) : Modifier.Node(), FocusPropertiesModifierNode, FocusRequesterModifierNode, CompositionLocalConsumerModifierNode {
    private var pinned: PinnableContainer.PinnedHandle? = null

    private fun drop() {
        val h = pinned; pinned = null
        if (h != null) runCatching { h.release() }
    }

    private val onExit: (androidx.compose.ui.focus.FocusDirection) -> FocusRequester = {
        if (saveFocusedChild()) { drop(); pinned = currentValueOf(LocalPinnableContainer)?.pin() }
        FocusRequester.Default
    }
    private val onEnter: (androidx.compose.ui.focus.FocusDirection) -> FocusRequester = {
        if (restoreFocusedChild()) FocusRequester.Cancel
        else { val r = onRestoreFailed?.invoke() ?: FocusRequester.Default; drop(); r }
    }

    override fun applyFocusProperties(focusProperties: FocusProperties) {
        focusProperties.enter = onEnter
        focusProperties.exit = onExit
    }

    override fun onDetach() { drop(); super.onDetach() }
}
