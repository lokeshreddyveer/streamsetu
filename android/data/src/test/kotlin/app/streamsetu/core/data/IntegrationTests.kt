package app.streamsetu.core.data

import app.streamsetu.core.data.repo.*
import app.streamsetu.core.security.InMemoryCredentialStore
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

/** A pretend web service: answers by address part, and remembers what was asked. */
class FakeWeb : Web {
    val requests = java.util.Collections.synchronizedList(ArrayList<WebRequest>())
    @Volatile var routes = listOf<Triple<String, Int, String>>()
    override suspend fun call(r: WebRequest): WebResponse {
        requests += r
        val hit = routes.lastOrNull { r.url.contains(it.first) } ?: Triple("", 404, "{}")
        return WebResponse(hit.second, hit.third)
    }
    fun asked(part: String) = requests.filter { it.url.contains(part) }
}

class DebridTests {
    private fun <T> run(b: suspend () -> T) = runBlocking { b() }
    private fun fails(message: String? = null, b: suspend () -> Unit) {
        try { runBlocking { b() }; fail("expected an error") } catch (e: DebridException) { if (message != null) assertEquals(message, e.message) }
    }

    @Test fun linksAndMagnetsAreToldApart() {
        assertEquals(DebridInput.Link("https://host.tld/file/abc"), DebridInput.parse("https://host.tld/file/abc"))
        assertEquals(DebridInput.Magnet("magnet:?xt=urn:btih:ABC123&dn=x"), DebridInput.parse("  magnet:?xt=urn:btih:ABC123&dn=x "))
        assertEquals(DebridInput.Invalid, DebridInput.parse("ftp://x/y")); assertEquals(DebridInput.Invalid, DebridInput.parse("hello")); assertEquals(DebridInput.Invalid, DebridInput.parse("magnet:?dn=nohash"))
    }

    @Test fun realDebridUnlocksALinkWithTheTokenInTheHeaderNotTheAddress() = run {
        val web = FakeWeb().apply { routes = listOf(Triple("/unrestrict/link", 200, """{"filename":"Film.mkv","download":"https://cdn.rd/d/Film.mkv"}""")) }
        val r = DebridClient(DebridService.REAL_DEBRID, "TOK", web).resolve("https://hoster.tld/f/1")
        assertEquals("https://cdn.rd/d/Film.mkv", r.url); assertEquals("Film.mkv", r.name)
        val req = web.asked("unrestrict/link").first()
        assertEquals("Bearer TOK", req.headers["Authorization"]); assertFalse(req.url.contains("TOK"))
        assertEquals("link=https%3A%2F%2Fhoster.tld%2Ff%2F1", req.body)
    }

    @Test fun allDebridUnlocksALink() = run {
        val web = FakeWeb().apply { routes = listOf(Triple("/link/unlock", 200, """{"status":"success","data":{"link":"https://ad.cdn/x.mp4","filename":"x.mp4"}}""")) }
        assertEquals("https://ad.cdn/x.mp4", DebridClient(DebridService.ALL_DEBRID, "K", web).resolve("https://h/f").url)
    }

    @Test fun premiumizePicksTheLargestVideo() = run {
        val web = FakeWeb().apply { routes = listOf(Triple("directdl", 200, """{"status":"success","content":[{"path":"a/readme.txt","size":10,"link":"https://p/readme"},{"path":"a/small.mkv","size":100,"link":"https://p/small"},{"path":"a/big.mkv","size":900,"link":"https://p/big","stream_link":"https://p/big-stream"}]}""")) }
        val r = DebridClient(DebridService.PREMIUMIZE, "K", web).resolve("https://h/f")
        assertEquals("big.mkv", r.name); assertEquals("https://p/big-stream", r.url)
    }

    @Test fun aBadTokenAndARefusalAreExplained() {
        val web = FakeWeb().apply { routes = listOf(Triple("/unrestrict/link", 401, """{"error":"bad_token"}""")) }
        fails("Real-Debrid did not accept the token.") { DebridClient(DebridService.REAL_DEBRID, "X", web).resolve("https://h/f") }
        web.routes = listOf(Triple("/unrestrict/link", 503, "{}"))
        fails { DebridClient(DebridService.REAL_DEBRID, "X", web).resolve("https://h/f") }
    }

    @Test fun noTokenAndNotALinkNeverReachTheNetwork() {
        val web = FakeWeb()
        fails("Add your debrid token in Settings first.") { DebridClient(DebridService.REAL_DEBRID, " ", web).resolve("https://h/f") }
        fails("That is not a link or a magnet link.") { DebridClient(DebridService.REAL_DEBRID, "T", web).resolve("nonsense") }
        assertTrue(web.requests.isEmpty())
    }

    @Test fun magnetsAreRefusedWhereTheyAreNotAllowed() {
        val web = FakeWeb()
        fails("Magnet links are not supported in this app.") { DebridClient(DebridService.REAL_DEBRID, "T", web, allowMagnets = false).resolve("magnet:?xt=urn:btih:ABC") }
        assertTrue(web.requests.isEmpty())
    }

    @Test fun realDebridMagnetSelectsTheLargestVideoThenUnlocksIt() = run {
        val web = FakeWeb().apply { routes = listOf(Triple("addMagnet", 201, """{"id":"T1"}"""),
            Triple("torrents/info/T1", 200, """{"status":"waiting_files_selection","files":[{"id":1,"path":"/a.nfo","bytes":5},{"id":2,"path":"/s.mkv","bytes":50},{"id":3,"path":"/b.mkv","bytes":500}]}"""),
            Triple("selectFiles/T1", 204, "{}")) }
        Thread { Thread.sleep(80); web.routes = web.routes + listOf(Triple("torrents/info/T1", 200, """{"status":"downloaded","links":["https://rd/l/1"]}"""), Triple("/unrestrict/link", 200, """{"filename":"b.mkv","download":"https://cdn/b.mkv"}""")) }.start()
        val r = DebridClient(DebridService.REAL_DEBRID, "T", web, pollEveryMs = 10, magnetWaitMs = 5000).resolve("magnet:?xt=urn:btih:ABC")
        assertEquals("https://cdn/b.mkv", r.url)
        assertEquals("files=3", web.asked("selectFiles/T1").first().body)
    }

    @Test fun aMagnetThatIsNotReadyInTimeSaysSo() {
        val web = FakeWeb().apply { routes = listOf(Triple("addMagnet", 201, """{"id":"T2"}"""), Triple("torrents/info/T2", 200, """{"status":"downloading"}""")) }
        fails { DebridClient(DebridService.REAL_DEBRID, "T", web, pollEveryMs = 10, magnetWaitMs = 100).resolve("magnet:?xt=urn:btih:ABC") }
    }

    @Test fun theTokenIsKeptInTheVault() {
        val d = DebridStore(InMemoryCredentialStore())
        assertFalse(d.load().isComplete)
        d.save(DebridAccount(DebridService.ALL_DEBRID, " abc "))
        assertEquals("abc", d.load().token); assertEquals(DebridService.ALL_DEBRID, d.load().service)
        d.save(DebridAccount(DebridService.ALL_DEBRID, "")); assertFalse(d.load().isComplete)
    }

    @Test fun aDirectLinkPlaysUnderAnIdOfItsOwn() {
        val id = DirectLinks.register("https://cdn/b.mkv")
        assertEquals("https://cdn/b.mkv", DirectLinks.urlOf(id)); assertNull(DirectLinks.urlOf("movie:1"))
    }
}

class TraktTests {
    private val app = TraktApp("CID", "SEC")
    private val tokens = TraktTokens("AT", "RT", System.currentTimeMillis() + 1_000_000_000)
    private fun fails(kind: TraktException.Kind? = null, b: suspend () -> Unit) {
        try { runBlocking { b() }; fail("expected an error") } catch (e: TraktException) { if (kind != null) assertEquals(kind, e.kind) }
    }

    @Test fun cleaningATitleTakesOffTheProvidersDecoration() {
        assertEquals("John Wick", TraktItem.cleanTitle("John Wick (2014) 4K HEVC")); assertEquals("The Matrix", TraktItem.cleanTitle("EN - The Matrix [1080p]")); assertEquals("Dune", TraktItem.cleanTitle("Dune"))
    }

    @Test fun signingInWithACodeWaitsThenGetsTokens() = runBlocking {
        val web = FakeWeb().apply { routes = listOf(Triple("device/code", 200, """{"device_code":"DC","user_code":"ABCD1234","verification_url":"https://trakt.tv/activate","expires_in":600,"interval":5}"""), Triple("device/token", 400, "{}")) }
        val c = TraktClient(app, web)
        val code = c.startDeviceLogin(); assertEquals("ABCD1234", code.userCode)
        assertNull(c.pollDeviceToken(code))
        web.routes = web.routes + Triple("device/token", 200, """{"access_token":"AT","refresh_token":"RT","expires_in":7776000,"created_at":1800000000}""")
        val t = c.pollDeviceToken(code)!!
        assertEquals("AT", t.access); assertEquals((1_800_000_000L + 7_776_000L) * 1000, t.expiresMs)
        assertTrue(web.asked("device/token").last().body!!.let { it.contains("\"client_id\":\"CID\"") && it.contains("\"client_secret\":\"SEC\"") && it.contains("\"code\":\"DC\"") })
    }

    @Test fun aRefusedOrExpiredCodeIsReported() {
        val web = FakeWeb().apply { routes = listOf(Triple("device/token", 410, "{}")) }
        val code = TraktDeviceCode("x", "y", "u", 1, 1)
        fails(TraktException.Kind.EXPIRED) { TraktClient(app, web).pollDeviceToken(code) }
        web.routes = listOf(Triple("device/token", 418, "{}"))
        fails(TraktException.Kind.DENIED) { TraktClient(app, web).pollDeviceToken(code) }
    }

    @Test fun aScrobbleCarriesTheTokenTheKeyAndTheProgress() = runBlocking {
        val web = FakeWeb().apply { routes = listOf(Triple("scrobble/stop", 201, "{}")) }
        TraktClient(app, web).scrobble(TraktClient.Scrobble.STOP, TraktItem.Movie("Dune", 2021), 96.0, tokens)
        val r = web.asked("scrobble/stop").first()
        assertEquals("Bearer AT", r.headers["Authorization"]); assertEquals("CID", r.headers["trakt-api-key"]); assertEquals("2", r.headers["trakt-api-version"])
        assertTrue(r.body!!.contains("\"progress\":96.0") && r.body!!.contains("\"title\":\"Dune\""))
    }

    @Test fun anUnknownTitleOrARepeatIsNotAnErrorButASignOutIs() = runBlocking {
        val web = FakeWeb().apply { routes = listOf(Triple("scrobble", 404, "{}")) }
        val c = TraktClient(app, web)
        c.scrobble(TraktClient.Scrobble.START, TraktItem.Movie("Obscure", null), 0.0, tokens)
        web.routes = listOf(Triple("scrobble", 409, "{}")); c.scrobble(TraktClient.Scrobble.START, TraktItem.Movie("Dune", 2021), 0.0, tokens)
        web.routes = listOf(Triple("scrobble", 401, "{}"))
        fails(TraktException.Kind.NOT_SIGNED_IN) { c.scrobble(TraktClient.Scrobble.START, TraktItem.Movie("Dune", 2021), 0.0, tokens) }
    }

    @Test fun theWatchlistReadsMoviesAndShows() = runBlocking {
        val web = FakeWeb().apply { routes = listOf(Triple("watchlist/movies", 200, """[{"movie":{"title":"Dune","year":2021}}]"""), Triple("watchlist/shows", 200, """[{"show":{"title":"Severance","year":2022}}]""")) }
        assertEquals(listOf(TraktListed("Dune", 2021, false), TraktListed("Severance", 2022, true)), TraktClient(app, web).watchlist(tokens))
    }

    @Test fun watchlistTitlesMatchTheLibraryByNameAndYear() {
        val dune = TraktListed("Dune", 2021, false)
        assertTrue(TraktItem.matches(dune, "Dune (2021) 4K", 2021)); assertTrue(TraktItem.matches(dune, "DUNE", null))
        assertFalse(TraktItem.matches(dune, "Dune", 1984)); assertFalse(TraktItem.matches(dune, "Dune Part Two", 2024))
    }

    @Test fun keysAndTokensAreKeptInTheVault() {
        val s = TraktStore(InMemoryCredentialStore())
        assertFalse(s.app().isComplete); assertNull(s.tokens())
        s.saveApp(TraktApp(" A ", " B ")); s.saveTokens(tokens)
        assertEquals(TraktApp("A", "B"), s.app()); assertEquals(tokens, s.tokens())
        s.saveTokens(null); assertNull(s.tokens())
    }
}

class AITests {
    private fun client(p: AIProvider, web: FakeWeb, key: String = "KEY", model: String = "", base: String = "") = AIClient(AIConfig(p, model, base, key), web)
    private fun fails(message: String? = null, b: suspend () -> Unit) {
        try { runBlocking { b() }; fail("expected an error") } catch (e: AIException) { if (message != null) assertEquals(message, e.message) }
    }

    @Test fun geminiSendsTheKeyInAHeaderAndReadsTheText() = runBlocking {
        val web = FakeWeb().apply { routes = listOf(Triple("generateContent", 200, """{"candidates":[{"content":{"parts":[{"text":"Hello"},{"text":" there"}]}}]}""")) }
        assertEquals("Hello there", client(AIProvider.GEMINI, web).ask("S", "P"))
        val r = web.requests.first()
        assertEquals("KEY", r.headers["x-goog-api-key"]); assertFalse(r.url.contains("KEY")); assertTrue(r.url.contains("gemini-2.5-flash-lite:generateContent"))
    }

    @Test fun claudeUsesItsOwnHeadersAndFormat() = runBlocking {
        val web = FakeWeb().apply { routes = listOf(Triple("/v1/messages", 200, """{"content":[{"type":"text","text":"Hi"}]}""")) }
        assertEquals("Hi", client(AIProvider.CLAUDE, web).ask("S", "P"))
        val r = web.requests.first()
        assertEquals("KEY", r.headers["x-api-key"]); assertEquals("2023-06-01", r.headers["anthropic-version"])
        assertTrue(r.body!!.contains("\"system\":\"S\"") && r.body!!.contains("claude-haiku-5-5") && r.body!!.contains("\"max_tokens\":700"))
    }

    @Test fun openAIAndOpenRouterUseBearerAndChatMessages() = runBlocking {
        for ((p, host) in listOf(AIProvider.OPENAI to "api.openai.com", AIProvider.OPENROUTER to "openrouter.ai")) {
            val web = FakeWeb().apply { routes = listOf(Triple("chat/completions", 200, """{"choices":[{"message":{"content":"Yo"}}]}""")) }
            assertEquals("Yo", client(p, web).ask("S", "P"))
            val r = web.requests.first()
            assertTrue(r.url.contains(host)); assertEquals("Bearer KEY", r.headers["Authorization"]); assertTrue(r.body!!.indexOf("\"system\"") < r.body!!.indexOf("\"user\""))
        }
    }

    @Test fun ollamaNeedsNoKeyAndTakesTheAddressItIsGiven() = runBlocking {
        val web = FakeWeb().apply { routes = listOf(Triple("/api/chat", 200, """{"message":{"role":"assistant","content":"Local"}}""")) }
        assertEquals("Local", client(AIProvider.OLLAMA, web, key = "", base = "192.168.1.20:11434/").ask("S", "P"))
        val r = web.requests.first()
        assertEquals("http://192.168.1.20:11434/api/chat", r.url); assertNull(r.headers["Authorization"]); assertTrue(r.body!!.contains("\"stream\":false"))
    }

    @Test fun aMissingKeyNeverReachesTheNetwork() {
        val web = FakeWeb()
        fails("Choose an AI in Settings first.") { client(AIProvider.CLAUDE, web, key = " ").ask("S", "P") }
        assertTrue(web.requests.isEmpty())
    }

    @Test fun refusalsAreExplainedInPlainWords() {
        val web = FakeWeb().apply { routes = listOf(Triple("messages", 401, "{}")) }
        fails("Anthropic Claude did not accept the key.") { client(AIProvider.CLAUDE, web).ask("S", "P") }
        web.routes = listOf(Triple("messages", 429, "{}")); fails { client(AIProvider.CLAUDE, web).ask("S", "P") }
        web.routes = listOf(Triple("messages", 404, "{}")); fails { client(AIProvider.CLAUDE, web, model = "nope").ask("S", "P") }
    }

    @Test fun theAnswerIsReadEvenInsideACodeBlock() {
        val a = "Sure!\n```json\n{\"search\":\"telugu thriller 2010s\",\"titles\":[\"Inception (2010)\",\"\"],\"note\":\"Mind-bending.\"}\n```"
        assertEquals(WatchSuggestion("telugu thriller 2010s", listOf("Inception (2010)"), "Mind-bending."), WatchAdvisor.parse(a))
        assertNull(WatchAdvisor.parse("I cannot help with that")); assertNull(WatchAdvisor.parse("{\"search\":\"\",\"titles\":[],\"note\":\"x\"}"))
        assertEquals("Inception" to 2010, WatchAdvisor.split("Inception (2010)"))
    }

    @Test fun onlyWhatThePersonTypedGoesInThePrompt() {
        assertEquals("What I feel like watching: something light", WatchAdvisor.prompt("  something light  "))
        assertFalse(WatchAdvisor.SYSTEM.lowercase().contains("playlist"))
    }

    @Test fun theChoiceIsKeptAndTheKeyIsSeparatePerProvider() {
        val s = AIStore(InMemoryCredentialStore())
        assertEquals(AIProvider.GEMINI, s.provider)
        s.save(AIConfig(AIProvider.CLAUDE, " claude-x ", "", " KEYC ")); s.save(AIConfig(AIProvider.OPENAI, "", "", "KEYO"))
        assertEquals(AIProvider.OPENAI, s.provider)
        assertEquals("KEYC", s.load(AIProvider.CLAUDE).key); assertEquals("claude-x", s.load(AIProvider.CLAUDE).model)
        assertEquals("KEYO", s.load(AIProvider.OPENAI).key); assertEquals("gpt-4o-mini", s.load(AIProvider.OPENAI).effectiveModel)
        assertFalse(s.load(AIProvider.GEMINI).isReady)
    }

    @Test fun everyProviderShowsItsCostAndWhereToGetAKey() {
        AIProvider.entries.forEach { assertTrue(it.pricing.isNotEmpty() && it.keyHelp.isNotEmpty() && it.pricingUrl.startsWith("https://")) }
    }
}
