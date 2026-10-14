package app.streamsetu.core.data.repo

/** Where a folder goes in the person's order. */
enum class MoveTo { UP, DOWN, FIRST, LAST }

/**
 * Pure ordering rules, so they can be tested without a database. [ids] is the list as shown (pinned first, then the person's order); the result is the new order,
 * or null when the move is not possible (already at that edge, or the folder is not in the list). Nothing else in the list changes place.
 */
object FolderOrder {
    fun move(ids: List<String>, id: String, to: MoveTo): List<String>? {
        val i = ids.indexOf(id); if (i < 0) return null
        val j = when (to) { MoveTo.UP -> i - 1; MoveTo.DOWN -> i + 1; MoveTo.FIRST -> 0; MoveTo.LAST -> ids.lastIndex }
        if (j !in ids.indices || j == i) return null
        return ids.toMutableList().also { it.removeAt(i); it.add(j, id) }
    }
    fun canMove(ids: List<String>, id: String, to: MoveTo) = move(ids, id, to) != null
}
