package app.streamsetu.core.data.repo

/** Who may see what in Search, as one word. Equal words mean the same person with the same permissions; any difference means everything on screen from before must go. */
object SearchContext {
    fun key(profileId: String, sourceIds: Collection<String>, hideAdult: Boolean, lockedFolderIds: Collection<String>, hiddenChannelIds: Collection<String>): String =
        listOf(profileId, sourceIds.sorted().joinToString(","), hideAdult.toString(), lockedFolderIds.sorted().joinToString(","), hiddenChannelIds.sorted().joinToString(",")).joinToString("|")
}
