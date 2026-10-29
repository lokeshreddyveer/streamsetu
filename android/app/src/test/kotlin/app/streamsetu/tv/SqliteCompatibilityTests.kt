package app.streamsetu.tv

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The oldest supported Android and Fire OS have an old SQLite (Android 9 has 3.22; Fire OS 5, 6 and 7 are API 22, 25 and 28). The unit tests run on a newer one, so they would not notice
 * SQL that the devices cannot parse, and a statement like that in a trigger stops the database opening at all. This reads the source for the newer syntax.
 */
class SqliteCompatibilityTests {
    private val root = generateSequence(File("").absoluteFile) { it.parentFile }.first { File(it, "settings.gradle.kts").exists() }

    @Test fun noSqlInTheSourceNeedsANewerSqliteThanTheOldestDevices() {
        val newer = listOf("DO UPDATE", "DO NOTHING", "RETURNING ", "RENAME COLUMN", "DROP COLUMN", "ROW_NUMBER", " OVER (", "->>", "IIF(")        // upsert 3.24, returning 3.35, rename/drop column 3.25/3.35, window functions 3.25, ->> 3.38, iif 3.32
        val hits = root.walkTopDown()
            .filter { it.extension == "kt" && "/src/main/" in it.path && "/build/" !in it.path }
            .flatMap { f -> f.readLines().mapIndexed { i, l -> Triple(f, i + 1, l) }.asSequence() }
            .filter { (_, _, line) -> !line.trimStart().startsWith("//") && !line.trimStart().startsWith("*") && newer.any { line.contains(it) } }
            .map { (f, n, l) -> "${f.relativeTo(root)}:$n  ${l.trim().take(100)}" }.toList()
        assertTrue("SQL newer than SQLite 3.22: $hits", hits.isEmpty())
    }
}
