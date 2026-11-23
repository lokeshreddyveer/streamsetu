package app.streamsetu.core.data.repo

import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.transform

/**
 * Batches bursts: the first value passes at once, then at most one value per [windowMs] follows, always the newest.
 * A burst of many writes therefore makes a few updates, never one per write, and the last value is never lost.
 */
fun <T> Flow<T>.coalesce(windowMs: Long): Flow<T> =
    distinctUntilChanged().conflate().transform { v -> emit(v); delay(windowMs) }
