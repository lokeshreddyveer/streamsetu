package app.streamsetu.tv.ui.screens.settings

/** Whether Essential lists a setting. Advanced lists everything. A setting that is not listed keeps its value and keeps working. */
enum class Exposure { ESSENTIAL, ADVANCED }

/** One control of Settings, described once. */
data class SettingDef(
    val id: String, val title: String, val description: String, val category: Category, val exposure: Exposure, val keywords: List<String>,
    /** Its value is something private (a key, a token, a PIN, a login): it is never shown in a list, a search result or the assistant's catalog. */
    val sensitive: Boolean,
    /** Other words people use for it ("dns" for App DNS, "lag" for the buffer). Written by hand in [SettingsRegistry]. */
    val aliases: List<String> = emptyList(),
    /** Where it exists: "tv", "phone". A setting is never listed on a device that does not have it. */
    val platforms: Set<String> = setOf("tv", "phone"),
    /** What the device must offer for the setting to be usable, or null. */
    val capability: String? = null,
) {
    /** The row search opens and focuses on its page: rows are found by title, so this is the title. */
    val focusTargetId: String get() = title
}

/**
 * The one list of what Settings has. Essential and Advanced, Settings search and what the assistant may be told about settings all read this, so they cannot disagree with each
 * other. It describes settings; it never holds a value.
 */
object SettingsRegistry {
    /** Words people search by that the titles do not hold. Keyed by setting id; a test fails if an id here is not a setting. */
    internal val aliases: Map<String, List<String>> = mapOf(
        "subtitles.size" to listOf("subtitle size", "caption size", "font size subtitles", "text size subtitles"),
        "subtitles.background" to listOf("subtitle background", "caption box"), "subtitles.outline" to listOf("subtitle outline", "caption outline"),
        "subtitles.subtitle-delay" to listOf("sync subtitles", "subtitle offset", "subtitles late", "subtitles early"),
        "subtitles.subtitle-language" to listOf("caption language", "subtitle language"), "subtitles.fetch-automatically" to listOf("download subtitles", "opensubtitles"),
        "playback.use-app-dns" to listOf("dns", "private dns", "dns over https", "doh", "cloudflare", "blocked provider", "provider blocked"), "playback.dns-provider" to listOf("dns", "cloudflare", "google dns", "quad9"),
        "playback.test-app-dns" to listOf("dns test", "check dns"), "playback.clear-dns-cache" to listOf("dns", "flush dns"), "playback.use-system-dns-for-local-devices" to listOf("dns", "local names"),
        "playback.live-tv-buffer" to listOf("buffer", "buffering", "lag", "stutter", "freezing", "channel delay"), "playback.movies-and-series-buffer" to listOf("buffer", "buffering", "stutter", "movie lag"),
        "playback.default-engine" to listOf("player", "exoplayer", "mpv", "media3"), "playback.proxy" to listOf("vpn", "socks", "http proxy"),
        "playback.match-the-tv-s-frame-rate" to listOf("frame rate", "refresh rate", "24p", "judder", "match display"),
        "privacy.remove-the-pin" to listOf("parental pin", "pin code", "kids lock", "child lock", "parental control"), "privacy.hide-adult-folders" to listOf("parental control", "kids", "adult content"),
        "privacy.lock-folders-again" to listOf("relock", "lock folders", "parental pin"), "privacy.clear-playback-history" to listOf("delete history", "watch history"), "privacy.clear-recent-searches" to listOf("search history"),
        "storage.clear-the-artwork-cache" to listOf("clear cache", "free space", "pictures", "posters cache"), "storage.rebuild-the-search-index" to listOf("search broken", "search not working", "index"),
        "storage.create-a-backup" to listOf("backup", "export settings"), "storage.restore-from-a-file" to listOf("restore", "import backup"), "storage.reset-all-settings" to listOf("factory reset", "defaults"),
        "audio.surround-sound-passthrough" to listOf("dolby", "dts", "atmos", "hdmi audio", "5.1", "soundbar"), "audio.audio-sync-offset" to listOf("lip sync", "audio delay", "audio late"),
        "audio.preferred-audio-language" to listOf("language", "dub", "dubbed", "original audio"), "appearance.theme" to listOf("dark mode", "colours", "colors", "look"), "appearance.poster-size" to listOf("bigger posters", "smaller posters"),
        "appearance.language" to listOf("app language", "hindi", "telugu"),
        "appearance.projector-mode" to listOf("projector", "brightness", "bright", "dark screen", "washed out", "contrast", "cannot see", "hdmi", "display"), "live.refresh-guide-now" to listOf("epg", "tv guide", "programme guide"), "live.guide-time-shift" to listOf("epg offset", "guide wrong time"),
    )

    val all: List<SettingDef> = SETTING_DEFS.map { d -> aliases[d.id]?.let { d.copy(aliases = it) } ?: d }

    /** The pages Essential leaves out. */
    val advancedCategories: Set<Category> = setOf(Category.CHANNELS, Category.DEVICE, Category.STATISTICS, Category.PODCASTS, Category.INTEGRATIONS, Category.SYNC, Category.ADDONS, Category.STORAGE, Category.DIAGNOSTICS)

    /** The function that draws each part of a page, and the page it belongs to (used to check the list against the code). */
    val pageFunctions: Map<String, Category> = mapOf(
        "PlaybackSettings" to Category.PLAYBACK, "AppDnsGroup" to Category.PLAYBACK, "VideoSettings" to Category.VIDEO, "AudioSettings" to Category.AUDIO, "SubtitleSettings" to Category.SUBTITLES,
        "LiveSettings" to Category.LIVE, "RemindersSettings" to Category.LIVE, "GuideAlertsSettings" to Category.LIVE, "ScheduledRecordingsSettings" to Category.LIVE, "GuideSettingsContent" to Category.LIVE,
        "ChannelManagerSettings" to Category.CHANNELS, "DeviceSettings" to Category.DEVICE, "WeeklyDigestSettings" to Category.STATISTICS, "StatisticsSettings" to Category.STATISTICS,
        "LibrarySettings" to Category.LIBRARIES, "FolderResets" to Category.LIBRARIES, "SearchSettings" to Category.SEARCH, "FavouriteSettings" to Category.FAVOURITES, "AppearanceSettings" to Category.APPEARANCE,
        "PrivacySettings" to Category.PRIVACY, "PrivacyReportSettings" to Category.PRIVACY, "ViewingLimitSettings" to Category.PRIVACY, "PodcastSettings" to Category.PODCASTS,
        "IntegrationsSettings" to Category.INTEGRATIONS, "TraktSettings" to Category.INTEGRATIONS, "DebridSettings" to Category.INTEGRATIONS, "AiSettings" to Category.INTEGRATIONS, "AskAiSettings" to Category.INTEGRATIONS,
        "ProfileSettings" to Category.PROFILES, "SyncSettings" to Category.SYNC, "AddonsSettings" to Category.ADDONS, "StorageSettings" to Category.STORAGE,
        "DiagnosticsSettings" to Category.DIAGNOSTICS, "PlaybackCapabilitiesGroup" to Category.DIAGNOSTICS, "AboutSettings" to Category.ABOUT, "UpdateSettings" to Category.ABOUT,
    )

    fun visible(advanced: Boolean): List<SettingDef> = if (advanced) all else all.filter { it.exposure == Exposure.ESSENTIAL && it.category !in advancedCategories }

    /** Settings that match [query], best first: a title that starts with the words, then one that contains them, then a keyword, then the description. Words are matched in any order. */
    fun search(query: String, advanced: Boolean, limit: Int = 20): List<SettingDef> {
        val words = query.lowercase().split(' ', '-', '/').filter { it.length >= 2 }
        if (words.isEmpty()) return emptyList()
        return visible(advanced).mapNotNull { s -> score(s, words)?.let { s to it } }
            .sortedWith(compareByDescending<Pair<SettingDef, Int>> { it.second }.thenBy { it.first.title }).take(limit).map { it.first }
    }

    /** How well a setting matches every word, or null when one word matches nothing about it. */
    private fun score(s: SettingDef, words: List<String>): Int? {
        val title = s.title.lowercase(); val desc = s.description.lowercase(); val page = s.category.title.lowercase()
        var total = 0
        for (w in words) {
            total += when {
                title.startsWith(w) -> 40
                title.contains(w) -> 30
                s.aliases.any { it.lowercase().contains(w) } -> 35
                s.keywords.any { it.startsWith(w) } -> 20
                desc.contains(w) -> 10
                page.contains(w) -> 5
                else -> return null
            }
        }
        return total
    }

    /** What the assistant may be told about settings: what exists and where, never a value. Settings that hold something private are left out entirely. */
    fun assistantCatalog(advanced: Boolean = false): String = visible(advanced).filter { !it.sensitive }.joinToString("\n") { "${it.id}: ${it.title} (${it.category.title})" + if (it.description.isNotBlank()) " - ${it.description.take(120)}" else "" }
}
