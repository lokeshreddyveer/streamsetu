package app.streamsetu.tv.sports.multiview

/** A tile's place as fractions of the safe viewport (0..1). */
data class TileRect(val x: Float, val y: Float, val w: Float, val h: Float) {
    val cx get() = x + w / 2
    val cy get() = y + h / 2
}

enum class Dir { UP, DOWN, LEFT, RIGHT }

/**
 * Where each slot is. Slot 0 is the primary. Two tiles sit side by side; three put the primary on the left at two thirds of the width with the others stacked beside it; four are a grid.
 * The tiles keep their own views: a tile that becomes primary only changes slot, so its picture is moved and never rebuilt.
 */
object MultiviewLayout {
    private const val BIG = 2f / 3f

    fun rects(count: Int, portrait: Boolean = false): List<TileRect> = if (portrait) portraitRects(count) else when (count) {
        0 -> emptyList()
        1 -> listOf(TileRect(0f, 0f, 1f, 1f))
        2 -> listOf(TileRect(0f, 0f, 0.5f, 1f), TileRect(0.5f, 0f, 0.5f, 1f))
        3 -> listOf(TileRect(0f, 0f, BIG, 1f), TileRect(BIG, 0f, 1f - BIG, 0.5f), TileRect(BIG, 0.5f, 1f - BIG, 0.5f))
        else -> listOf(TileRect(0f, 0f, 0.5f, 0.5f), TileRect(0.5f, 0f, 0.5f, 0.5f), TileRect(0f, 0.5f, 0.5f, 0.5f), TileRect(0.5f, 0.5f, 0.5f, 0.5f))
    }

    /** The same layouts for a tall screen (a phone held upright): two are stacked, and the large primary of three sits on top. */
    private fun portraitRects(count: Int): List<TileRect> = when (count) {
        0 -> emptyList()
        1 -> listOf(TileRect(0f, 0f, 1f, 1f))
        2 -> listOf(TileRect(0f, 0f, 1f, 0.5f), TileRect(0f, 0.5f, 1f, 0.5f))
        3 -> listOf(TileRect(0f, 0f, 1f, BIG), TileRect(0f, BIG, 0.5f, 1f - BIG), TileRect(0.5f, BIG, 0.5f, 1f - BIG))
        else -> listOf(TileRect(0f, 0f, 0.5f, 0.5f), TileRect(0.5f, 0f, 0.5f, 0.5f), TileRect(0f, 0.5f, 0.5f, 0.5f), TileRect(0.5f, 0.5f, 0.5f, 0.5f))
    }

    /** Moves the tile at [from] to the front, keeping the others in order. */
    fun <T> makePrimary(order: List<T>, from: Int): List<T> = if (from !in order.indices || from == 0) order else listOf(order[from]) + order.filterIndexed { i, _ -> i != from }
}

/** Geometric movement between slots. Returns null at an edge: the remote stays where it is, so nothing is ever left by an accidental direction key. */
object MultiviewNav {
    fun move(rects: List<TileRect>, from: Int, dir: Dir): Int? {
        val a = rects.getOrNull(from) ?: return null
        var best: Int? = null; var bestScore = Float.MAX_VALUE
        for ((i, r) in rects.withIndex()) {
            if (i == from) continue
            val along: Float; val across: Float
            when (dir) {
                Dir.RIGHT -> { if (r.cx <= a.cx + EPS || r.x < a.x + a.w - EPS) continue; along = r.x - (a.x + a.w); across = kotlin.math.abs(r.cy - a.cy) }
                Dir.LEFT -> { if (r.cx >= a.cx - EPS || r.x + r.w > a.x + EPS) continue; along = a.x - (r.x + r.w); across = kotlin.math.abs(r.cy - a.cy) }
                Dir.DOWN -> { if (r.cy <= a.cy + EPS || r.y < a.y + a.h - EPS) continue; along = r.y - (a.y + a.h); across = kotlin.math.abs(r.cx - a.cx) }
                Dir.UP -> { if (r.cy >= a.cy - EPS || r.y + r.h > a.y + EPS) continue; along = a.y - (r.y + r.h); across = kotlin.math.abs(r.cx - a.cx) }
            }
            val score = along * 4 + across                                                   // the nearest in the direction, then the best aligned; a tie goes to the lower slot
            if (score < bestScore - 1e-6f) { bestScore = score; best = i }
        }
        return best
    }
    private const val EPS = 1e-4f
}
