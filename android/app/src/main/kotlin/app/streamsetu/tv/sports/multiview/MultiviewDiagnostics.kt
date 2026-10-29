package app.streamsetu.tv.sports.multiview

import app.streamsetu.tv.trace.SSTrace

enum class MultiviewStage { REQUESTED, TILE_STARTED, TILE_FAILED, ALLOCATION_FAILED, AUDIO_CHANGED, PRIMARY_CHANGED, FEED_SWITCHED, FEED_RESTORED, TILE_REMOVED, STOPPED }

enum class TileFailure { NETWORK, REFUSED, NOT_FOUND, TIMEOUT, FORMAT, NO_DECODER, UNAVAILABLE, OTHER }

/**
 * One step of a Multi-View, as numbers and fixed words only: no event, team, channel or connection name, no address, header or credential. [ms] is measured from the request that began the step.
 */
class MultiviewReport(
    val stage: MultiviewStage,
    val requestedTiles: Int,
    val supportedLimit: Int,
    val startedTiles: Int,
    val failure: TileFailure?,
    val ms: Long,
    val memoryClassMb: Int = 0,
) {
    fun line(): String = buildString {
        append("multiview stage=").append(stage.name.lowercase()).append(" requested=").append(requestedTiles).append(" limit=").append(supportedLimit).append(" started=").append(startedTiles)
        failure?.let { append(" error=").append(it.name.lowercase()) }
        append(" ms=").append(ms)
        if (memoryClassMb > 0) append(" memClass=").append(memoryClassMb)
    }
}

fun interface MultiviewDiagnostics {
    fun record(report: MultiviewReport)

    object Log : MultiviewDiagnostics {
        override fun record(report: MultiviewReport) { SSTrace.v { report.line() } }
    }
}
