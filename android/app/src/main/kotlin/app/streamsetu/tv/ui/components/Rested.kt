package app.streamsetu.tv.ui.components

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.collectLatest

/** The first value at once; every later one only after it has stayed [restMs] with no newer value behind it (a run of quick changes gives just the last). */
fun <T> Flow<T>.rested(restMs: Long): Flow<T> = channelFlow {
    var first = true
    collectLatest { v -> if (first) { first = false; send(v) } else { delay(restMs); send(v) } }
}

/**
 * [value], but only once it has stayed the same for [restMs]. A pane that is costly to build (it reads the guide and the player) can follow a remote that is held down without being
 * built for every step on the way: the first value shows at once, a run of changes shows the last one after it rests, and what moves with the remote itself (the focus) is not touched.
 */
@Composable
fun <T> rememberRested(value: T, restMs: Long): T {
    var shown by remember { mutableStateOf(value) }
    val latest by rememberUpdatedState(value)
    LaunchedEffect(restMs) { snapshotFlow { latest }.rested(restMs).collect { shown = it } }
    return shown
}
