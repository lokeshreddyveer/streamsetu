package app.streamsetu.core.data.smartmix

import java.io.File

class FakeCandidateSource(
    var library: List<Candidate> = emptyList(),
    var signals: Signals = Signals(),
) : CandidateSource {
    val requests = ArrayList<PoolRequest>()
    override fun pool(request: PoolRequest): List<Candidate> { requests.add(request); return library }
    override fun signals(profileId: String) = signals
    override fun matchCandidates(profileId: String) = library
}

class FakeFetcher(var result: TrendingSnapshot? = null) : TrendingFetcher {
    var calls = 0
    val keysSeen = ArrayList<String>()
    override fun fetchWeekly(apiKey: String): TrendingSnapshot? { calls++; keysSeen.add(apiKey); return result }
}

fun cand(i: Int, kind: Kind = Kind.MOVIE, year: Int? = 2024, lang: String? = "Telugu", franchise: String? = null, genre: String? = null, q: Int = 3,
         poster: Boolean = true, backdrop: Boolean = false, watched: Boolean = false, rating: String? = null, cam: Boolean = false,
         id: String = "m$i", key: String = "k$i", added: Int? = 10 + i % 400) =
    Candidate(id = id, kind = kind, identityKey = key, year = year, addedDays = added, ratingText = rating, qualityRank = q, isCam = cam, lang = lang,
        franchiseKey = franchise, primaryGenre = genre, hasPoster = poster, hasBackdrop = backdrop, watched = watched, completed = watched)

object FixtureFiles {
    fun dir(): File? {
        System.getenv("SMARTMIX_FIXTURES")?.let { File(it).takeIf { f -> f.isDirectory }?.let { f -> return f } }
        var d: File? = File(System.getProperty("user.dir")).absoluteFile
        while (d != null) {
            File(d, "smartmix/fixtures").takeIf { it.isDirectory }?.let { return it }
            File(d.parentFile, "smartmix/fixtures").takeIf { it.isDirectory }?.let { return it }
            d = d.parentFile
        }
        return null
    }
}
