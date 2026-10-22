package app.streamsetu.core.data.repo

import app.streamsetu.core.security.CredentialStore
import kotlinx.serialization.json.*

/**
 * The AI the person has chosen to ask. They bring their own account: an API key from the provider (kept in encrypted storage and sent only to that provider), or a model of their own on their
 * network (Ollama). Only the words the person types are sent: never a playlist address, a login, or what they have watched.
 */
enum class AIProvider(val title: String, val needsKey: Boolean, val keyHelp: String, val defaultModel: String, val pricing: String, val pricingUrl: String) {
    GEMINI("Google Gemini", true, "Free key at aistudio.google.com/apikey", "gemini-2.5-flash-lite",
        "Free tier with no card (low limits: roughly a couple of requests a minute and tens to a thousand a day, depending on the model; Google may use free-tier data to improve its products). Paid: about \$0.10 to \$0.30 per million words in and \$0.40 to \$2.50 out for the small models.",
        "https://ai.google.dev/gemini-api/docs/pricing"),
    OPENROUTER("OpenRouter", true, "Key at openrouter.ai/keys", "meta-llama/llama-3.3-70b-instruct:free",
        "Free models (names ending in :free): 20 requests a minute, and 50 a day, or 1,000 a day once you have bought \$10 of credit. Paid models are billed at the price of the model you choose.",
        "https://openrouter.ai/docs/api/reference/limits"),
    CLAUDE("Anthropic Claude", true, "Key at console.anthropic.com", "claude-haiku-5-5",
        "No free API tier. Small model about \$0.10 to \$1 per million words in and \$0.50 to \$5 out; mid-size about \$3 in and \$15 out.",
        "https://docs.anthropic.com/en/docs/about-claude/pricing"),
    OPENAI("OpenAI", true, "Key at platform.openai.com/api-keys", "gpt-4o-mini",
        "No free API tier. Small models about \$0.15 to \$0.75 per million words in and \$0.60 to \$4.50 out.", "https://openai.com/api/pricing/"),
    OLLAMA("Ollama (your own computer)", false, "Install Ollama on a computer on your network, and give its address.", "llama3.2",
        "Free. Runs on your own computer; speed depends on that computer.", "https://ollama.com");

    val defaultBase get() = if (this == OLLAMA) "http://localhost:11434" else ""
    companion object { const val PRICES_AS_OF = "October 2026"; const val PRICES_NOTE = "Prices and free limits change. A typical question uses a few hundred words, a fraction of a cent on a small model." }
}

data class AIConfig(val provider: AIProvider = AIProvider.GEMINI, val model: String = "", val base: String = "", val key: String = "") {
    val effectiveModel get() = model.trim().ifEmpty { provider.defaultModel }
    val effectiveBase get() = base.trim().ifEmpty { provider.defaultBase }
    val isReady get() = if (provider == AIProvider.OLLAMA) effectiveBase.isNotEmpty() else key.isNotBlank()
}

class AIException(message: String) : Exception(message)

class AIClient(private val config: AIConfig, private val web: Web = LiveWeb) {
    suspend fun ask(system: String, prompt: String): String {
        if (!config.isReady) throw AIException("Choose an AI in Settings first.")
        return when (config.provider) {
            AIProvider.GEMINI -> gemini(system, prompt)
            AIProvider.OPENROUTER -> chat("https://openrouter.ai/api/v1/chat/completions", system, prompt, mapOf("X-Title" to "StreamSetu"))
            AIProvider.OPENAI -> chat("https://api.openai.com/v1/chat/completions", system, prompt)
            AIProvider.CLAUDE -> claude(system, prompt)
            AIProvider.OLLAMA -> ollama(system, prompt)
        }
    }

    private fun msgs(system: String, prompt: String) = buildJsonArray {
        add(buildJsonObject { put("role", "system"); put("content", system) }); add(buildJsonObject { put("role", "user"); put("content", prompt) })
    }

    private suspend fun gemini(system: String, prompt: String): String {
        val model = java.net.URLEncoder.encode(config.effectiveModel, "UTF-8").replace("+", "%20")
        val body = buildJsonObject {
            put("system_instruction", buildJsonObject { put("parts", buildJsonArray { add(buildJsonObject { put("text", system) }) }) })
            put("contents", buildJsonArray { add(buildJsonObject { put("role", "user"); put("parts", buildJsonArray { add(buildJsonObject { put("text", prompt) }) }) }) })
        }
        val j = send("https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent", body, mapOf("x-goog-api-key" to config.key.trim()))
        val text = j.obj()?.get("candidates").arr()?.firstOrNull().obj()?.get("content").obj()?.get("parts").arr().orEmpty().mapNotNull { it.obj()?.get("text").str() }.joinToString("")
        return text.ifEmpty { throw AIException("The AI's answer could not be read. Try asking again.") }
    }

    private suspend fun chat(url: String, system: String, prompt: String, extra: Map<String, String> = emptyMap()): String {
        val body = buildJsonObject { put("model", config.effectiveModel); put("messages", msgs(system, prompt)) }
        val j = send(url, body, mapOf("Authorization" to "Bearer ${config.key.trim()}") + extra)
        val text = j.obj()?.get("choices").arr()?.firstOrNull().obj()?.get("message").obj()?.get("content").str().orEmpty()
        return text.ifEmpty { throw AIException("The AI's answer could not be read. Try asking again.") }
    }

    private suspend fun claude(system: String, prompt: String): String {
        val body = buildJsonObject {
            put("model", config.effectiveModel); put("max_tokens", 700); put("system", system)
            put("messages", buildJsonArray { add(buildJsonObject { put("role", "user"); put("content", prompt) }) })
        }
        val j = send("https://api.anthropic.com/v1/messages", body, mapOf("x-api-key" to config.key.trim(), "anthropic-version" to "2023-06-01"))
        val text = j.obj()?.get("content").arr().orEmpty().mapNotNull { it.obj()?.get("text").str() }.joinToString("")
        return text.ifEmpty { throw AIException("The AI's answer could not be read. Try asking again.") }
    }

    private suspend fun ollama(system: String, prompt: String): String {
        var base = config.effectiveBase
        if (!base.contains("://")) base = "http://$base"
        base = base.trimEnd('/')
        val body = buildJsonObject { put("model", config.effectiveModel); put("stream", false); put("messages", msgs(system, prompt)) }
        val j = send("$base/api/chat", body, emptyMap())
        val text = j.obj()?.get("message").obj()?.get("content").str().orEmpty()
        return text.ifEmpty { throw AIException("The AI's answer could not be read. Try asking again.") }
    }

    private suspend fun send(url: String, body: JsonObject, headers: Map<String, String>): JsonElement? {
        val res = try { web.call(WebRequest("POST", url, headers + mapOf("User-Agent" to "StreamSetu"), body.toString())) } catch (e: AIException) { throw e } catch (e: Exception) { throw AIException(e.message ?: "No answer.") }
        val j = parseJson(res.body)
        val name = config.provider.title
        when {
            res.status in 200..299 -> return j
            res.status == 401 || res.status == 403 -> throw AIException("$name did not accept the key.")
            res.status == 404 -> throw AIException("$name does not know the model \"${config.effectiveModel}\". Change the model name in Settings.")
            res.status == 429 -> throw AIException("$name says you have used up its limit for now. Wait a little, or change provider.")
            res.status >= 500 -> throw AIException("$name is not answering (${res.status}).")
            else -> throw AIException(reason(j) ?: "$name answered ${res.status}.")
        }
    }

    private fun reason(j: JsonElement?): String? = j.obj()?.get("error").obj()?.get("message").str() ?: j.obj()?.get("error").str()
}

/** "What should I watch?": the person's words in, a search for the library and some ideas out. */
data class WatchSuggestion(val search: String = "", val titles: List<String> = emptyList(), val note: String = "")

object WatchAdvisor {
    const val SYSTEM = """You help someone choose something to watch from their own library of films and series. Reply with JSON only, no other text, shaped like:
{"search": "...", "titles": ["Title (Year)", ...], "note": "..."}
"search" is a short search sentence using only these kinds of words: a language (such as telugu, hindi, english), a four-digit year or a decade like 2010s, "under 2 hours" or "over 2 hours", "unwatched", "favourites", "4K", "top rated", and at most three words of a title. Leave out anything else, and use an empty string if nothing fits.
"titles" is up to 8 real films or series that match what they ask for, with the year. Never invent a title.
"note" is one friendly sentence, no spoilers."""

    fun prompt(request: String) = "What I feel like watching: " + request.trim()

    /** Reads the answer even when the AI wraps it in a code block or adds a sentence around it. */
    fun parse(answer: String): WatchSuggestion? {
        val a = answer.indexOf('{'); val b = answer.lastIndexOf('}')
        if (a < 0 || b <= a) return null
        val j = parseJson(answer.substring(a, b + 1)).obj() ?: return null
        val titles = j["titles"].arr().orEmpty().mapNotNull { it.str()?.trim() }.filter { it.isNotEmpty() }.take(8)
        val s = WatchSuggestion(j["search"].str().orEmpty().trim(), titles, j["note"].str().orEmpty().trim())
        return if (s.search.isEmpty() && s.titles.isEmpty()) null else s
    }

    /** "Inception (2010)" -> ("Inception", 2010) */
    fun split(title: String): Pair<String, Int?> = TraktItem.cleanTitle(title) to Regex("""[\(\[]((?:19|20)\d{2})[\)\]]""").find(title)?.groupValues?.get(1)?.toInt()
}

/** The choice (provider, model, address) and the key, one key per provider, in encrypted storage. */
class AIStore(private val store: CredentialStore) {
    var provider: AIProvider
        get() = store.load("ai.provider")?.let { runCatching { AIProvider.valueOf(it) }.getOrNull() } ?: AIProvider.GEMINI
        set(v) = store.save("ai.provider", v.name)

    fun load(p: AIProvider = provider) = AIConfig(p, store.load("ai.model.${p.name}").orEmpty(), if (p == AIProvider.OLLAMA) store.load("ai.base").orEmpty() else "", if (p.needsKey) store.load("ai.key.${p.name}").orEmpty() else "")

    fun save(c: AIConfig) {
        provider = c.provider
        if (c.model.isBlank()) store.delete("ai.model.${c.provider.name}") else store.save("ai.model.${c.provider.name}", c.model.trim())
        if (c.provider == AIProvider.OLLAMA) { if (c.base.isBlank()) store.delete("ai.base") else store.save("ai.base", c.base.trim()) }
        if (c.provider.needsKey) { if (c.key.isBlank()) store.delete("ai.key.${c.provider.name}") else store.save("ai.key.${c.provider.name}", c.key.trim()) }
    }
}
