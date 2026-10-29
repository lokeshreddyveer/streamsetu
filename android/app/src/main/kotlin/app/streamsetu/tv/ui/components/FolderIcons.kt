package app.streamsetu.tv.ui.components

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.ui.graphics.vector.ImageVector

/**
 * Picks a fitting icon for a folder from its name, so the folder list says what each group is at a glance (the same rules as the Mac and iPhone apps). The first matching rule wins and
 * anything unrecognised gets a plain folder. Words match as whole words or word starts, so "Sports" matches "sport" but "Newsroom" does not match "us".
 */
object FolderIcons {
    private val rules: List<Pair<List<String>, ImageVector>> = listOf(
        listOf("news", "headline", "journal") to Icons.Filled.Newspaper,
        listOf("cricket", "ipl") to Icons.Filled.SportsCricket,
        listOf("football", "soccer", "premier league", "laliga", "bundesliga", "uefa", "fifa") to Icons.Filled.SportsSoccer,
        listOf("basketball", "nba") to Icons.Filled.SportsBasketball,
        listOf("tennis") to Icons.Filled.SportsTennis,
        listOf("golf") to Icons.Filled.SportsGolf,
        listOf("wrestling", "wwe", "ufc", "boxing", "mma", "fight") to Icons.Filled.SportsMma,
        listOf("racing", "formula", "f1", "motorsport", "motogp") to Icons.Filled.SportsMotorsports,
        listOf("sport", "espn", "bein", "sky sports") to Icons.Filled.EmojiEvents,
        listOf("kids", "children", "cartoon", "junior", "disney", "nick") to Icons.Filled.ChildCare,
        listOf("anime", "manga") to Icons.Filled.AutoAwesome,
        listOf("animation", "animated") to Icons.Filled.Brush,
        listOf("music", "mtv", "vevo", "hits", "radio fm", "songs") to Icons.Filled.MusicNote,
        listOf("radio") to Icons.Filled.Radio,
        listOf("documentary", "discovery", "nature", "history", "geographic", "science") to Icons.Filled.Public,
        listOf("weather") to Icons.Filled.WbSunny,
        listOf("shopping", "shop", "qvc") to Icons.Filled.ShoppingBag,
        listOf("religio", "islam", "christian", "gospel", "devotional", "church", "quran", "bhakti") to Icons.Filled.AccountBalance,
        listOf("horror", "scary") to Icons.Filled.NightsStay,
        listOf("comedy", "funny", "sitcom") to Icons.Filled.SentimentSatisfied,
        listOf("action", "adventure") to Icons.Filled.Bolt,
        listOf("romance", "romantic", "love") to Icons.Filled.Favorite,
        listOf("thriller", "crime", "mystery", "detective") to Icons.Filled.Visibility,
        listOf("sci-fi", "scifi", "science fiction", "fantasy") to Icons.Filled.AutoAwesome,
        listOf("drama", "entertainment", "general", "variety") to Icons.Filled.TheaterComedy,
        listOf("movie", "film", "cinema", "hollywood", "bollywood", "tollywood", "kollywood") to Icons.Filled.Movie,
        listOf("series", "tv show", "shows", "episodes", "season") to Icons.Filled.VideoLibrary,
        listOf("netflix", "prime", "hbo", "hulu", "apple tv", "paramount", "peacock", "hotstar", "zee5", "sony liv", "streaming") to Icons.Filled.PlayCircle,
        listOf("4k", "uhd", "2160") to Icons.Filled.Tv,
        listOf("premium", "vip", "gold", "exclusive") to Icons.Filled.WorkspacePremium,
        listOf("24/7", "24x7", "always") to Icons.Filled.Update,
        listOf("live", "events", "ppv", "pay per view") to Icons.Filled.Sensors,
        listOf("adult", "xxx", "18+") to Icons.Filled.Lock,
        listOf("india", "indian", "hindi", "telugu", "tamil", "malayalam", "kannada", "bengali", "punjabi", "marathi", "pakistan", "bangla", "asia", "arabic", "arab", "turk", "korea", "japan", "china") to Icons.Filled.Public,
        listOf("uk", "britain", "british", "europe", "france", "french", "german", "italy", "italian", "spain", "spanish", "portugal", "dutch", "nordic") to Icons.Filled.Public,
        listOf("usa", "us ", "united states", "america", "canada", "latin", "brazil", "mexico") to Icons.Filled.Public,
        listOf("favorite", "favourite", "my list") to Icons.Filled.Favorite,
        listOf("recent", "new", "latest") to Icons.Filled.AccessTime,
    )

    fun forName(name: String): ImageVector {
        val lower = " " + name.lowercase().map { if (it.isLetterOrDigit() || it in "+/") it.toString() else " " }.joinToString("") + " "
        for ((words, icon) in rules) for (w in words) {
            if (lower.contains(" $w") && (w.length > 3 || lower.contains(" $w ") || lower.contains(" ${w}s "))) return icon
        }
        return Icons.Filled.Folder
    }
}
