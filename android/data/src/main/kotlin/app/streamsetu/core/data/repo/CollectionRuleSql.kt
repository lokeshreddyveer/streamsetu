package app.streamsetu.core.data.repo

import app.streamsetu.core.model.CollectionRule
import app.streamsetu.core.model.ContentKind

/** What a rule asks of the database: conditions to join with AND, and the values for their question marks, in order. */
class RuleSql(val conditions: List<String>, val args: List<Any>)

/**
 * Turns a [CollectionRule] into conditions for the Movies and Series query (table alias `x`). Every value is passed as an argument, never written into the SQL, and every condition
 * uses columns that are indexed or small tables (the progress and favourites tables, the categories of one connection), so a list is read the same way a folder is.
 */
object CollectionRuleSql {
    private fun esc(text: String) = text.trim().lowercase().replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    private fun like(text: String) = "%" + esc(text) + "%"

    fun of(kind: ContentKind, r: CollectionRule): RuleSql {
        val c = ArrayList<String>(); val a = ArrayList<Any>()
        if (kind == ContentKind.CHANNEL) return RuleSql(listOf("1 = 0"), emptyList())          // a rule describes films and series; channels have no year, rating or progress
        r.sourceId?.let { c += "x.sourceId = ?"; a += it }
        r.yearFrom?.let { c += "x.year >= ?"; a += it }
        r.yearTo?.let { c += "x.year <= ?"; a += it }
        r.minRating?.let { c += "(x.rating IS NOT NULL AND x.rating != '' AND CAST(x.rating AS REAL) >= ?)"; a += it }
        r.language?.takeIf { it.isNotBlank() }?.let { l ->
            c += "(x.title LIKE ? ESCAPE '\\' OR x.title LIKE ? ESCAPE '\\' OR x.categoryId IN (SELECT id FROM categories WHERE name LIKE ? ESCAPE '\\'))"
            a += "%(" + esc(l) + "%"; a += "%[" + esc(l) + "%"; a += like(l)
        }
        if (r.unwatched) c += if (kind == ContentKind.SERIES) "NOT EXISTS (SELECT 1 FROM progress p WHERE p.seriesId = x.id)" else "NOT EXISTS (SELECT 1 FROM progress p WHERE p.itemId = x.id)"
        if (r.favoritesOnly) c += "EXISTS (SELECT 1 FROM favorites f WHERE f.itemId = x.id AND f.listId = 'favourites')"
        r.addedWithinDays?.let { c += "x.addedAt >= CAST(strftime('%s','now', ?) AS INTEGER)"; a += "-$it days" }
        r.titleContains?.takeIf { it.isNotBlank() }?.let { c += "LOWER(x.title) LIKE ? ESCAPE '\\'"; a += like(it) }
        r.folderContains?.takeIf { it.isNotBlank() }?.let { c += "x.categoryId IN (SELECT id FROM categories WHERE LOWER(name) LIKE ? ESCAPE '\\')"; a += like(it) }
        return RuleSql(c, a)
    }
}
