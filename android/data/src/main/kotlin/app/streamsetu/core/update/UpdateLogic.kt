package app.streamsetu.core.update

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

data class ReleaseAsset(val name: String, val url: String, val size: Long)

/** One published release that carries Android files: its tag, the Android version in it, the notes, and the files attached. */
data class ReleaseInfo(val tag: String, val version: String, val notes: String, val assets: List<ReleaseAsset>)

/**
 * The decisions the updater makes, kept free of Android so they can be tested: which releases count, which is newest, which file suits the device,
 * and which checksum belongs to it. Nothing here touches the network or the device.
 */
object UpdateLogic {
    const val TAG_PREFIX = "android-v"
    private val apkVersion = Regex("""\d+(?:\.\d+)+""")
    private val lenient = Json { ignoreUnknownKeys = true; isLenient = true }

    /** "0.6.2" -> [0, 6, 2]. A leading "v" and anything after a "-" (a pre-release label) are ignored; a part that is not a number counts as 0. */
    fun parts(version: String): List<Int> =
        version.trim().removePrefix("v").substringBefore('-').substringBefore('+').split('.').map { it.takeWhile { c -> c.isDigit() }.toIntOrNull() ?: 0 }

    /** True when [candidate] is a higher version than [installed] (compared number by number, so 0.6.10 is newer than 0.6.9). */
    fun isNewer(candidate: String, installed: String): Boolean {
        val a = parts(candidate); val b = parts(installed)
        for (i in 0 until maxOf(a.size, b.size)) {
            val x = a.getOrElse(i) { 0 }; val y = b.getOrElse(i) { 0 }
            if (x != y) return x > y
        }
        return false
    }

    /**
     * Reads GitHub's `releases` list and keeps the published releases that carry an Android APK (not drafts, not pre-releases). One release holds every app, so a
     * release is recognised by its files, and the Android version is the one in the APK's name ("StreamSetu-FireTV-0.9.1.apk" is 0.9.1); the older
     * `android-v0.6.2` tags still work. Anything unreadable is left out.
     */
    fun parse(json: String): List<ReleaseInfo> {
        val root = runCatching { lenient.parseToJsonElement(json) }.getOrNull() as? JsonArray ?: return emptyList()
        return root.mapNotNull { el ->
            val o = el as? JsonObject ?: return@mapNotNull null
            val tag = o["tag_name"]?.jsonPrimitive?.contentOrNull ?: return@mapNotNull null
            if (o["draft"]?.jsonPrimitive?.booleanOrNull == true || o["prerelease"]?.jsonPrimitive?.booleanOrNull == true) return@mapNotNull null
            val assets = (o["assets"] as? JsonArray).orEmpty().mapNotNull { a ->
                val ao = a as? JsonObject ?: return@mapNotNull null
                val name = ao["name"]?.jsonPrimitive?.contentOrNull ?: return@mapNotNull null
                val url = ao["browser_download_url"]?.jsonPrimitive?.contentOrNull ?: return@mapNotNull null
                ReleaseAsset(name, url, ao["size"]?.jsonPrimitive?.longOrNull ?: 0L)
            }
            val apk = assets.firstOrNull { it.name.endsWith(".apk", true) } ?: return@mapNotNull null
            val version = apkVersion.find(apk.name)?.value ?: tag.removePrefix(TAG_PREFIX).removePrefix("v")
            ReleaseInfo(tag, version, o["body"]?.jsonPrimitive?.contentOrNull.orEmpty(), assets)
        }
    }

    /** The highest version among the releases, or null when there are none. */
    fun latest(releases: List<ReleaseInfo>): ReleaseInfo? = releases.fold(null as ReleaseInfo?) { best, r -> if (best == null || isNewer(r.version, best.version)) r else best }

    /**
     * The file for this device: a television takes the television file ("streamsetu-tv-0.20.0.apk", or "StreamSetu-FireTV-0.19.0.apk" in earlier releases), a phone or
     * tablet the Android file. A release with only one APK (the older single-file releases) offers that one to both. Null when the release has no APK.
     */
    fun pickAsset(release: ReleaseInfo, television: Boolean): ReleaseAsset? {
        val apks = release.assets.filter { it.name.endsWith(".apk", true) }
        val wanted = if (television) listOf("-tv-", "-firetv-") else listOf("-android-")
        return apks.firstOrNull { a -> wanted.any { a.name.lowercase().contains(it) } } ?: apks.firstOrNull()
    }

    private val hash = Regex("(?<![0-9a-fA-F])[0-9a-fA-F]{64}(?![0-9a-fA-F])")

    /**
     * The SHA-256 published for a file. A line of the notes that names the file and holds a checksum wins; otherwise the first checksum in the notes
     * is used (the two Android files are the same build and share one). Null when the notes hold none, and then the file is not installed.
     */
    fun checksumFor(notes: String, assetName: String): String? {
        val lines = notes.lines()
        lines.firstOrNull { it.contains(assetName) && hash.containsMatchIn(it) }?.let { return hash.find(it)!!.value.lowercase() }
        return hash.find(notes)?.value?.lowercase()
    }
}
