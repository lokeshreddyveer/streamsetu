package app.streamsetu.tv.sync

import app.streamsetu.core.data.repo.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** The Trakt account on this device: sign-in by code, scrobbling, and the watchlist. Nothing is sent when signed out, for a private watch or in a kids profile (the caller checks the last two). */
class TraktService(private val store: TraktStore, private val scope: CoroutineScope, private val web: Web = LiveWeb) {
    sealed interface State {
        data object NotConfigured : State
        data object SignedOut : State
        data class WaitingForCode(val userCode: String, val url: String) : State
        data object SignedIn : State
    }

    private val _state = MutableStateFlow<State>(initial())
    val state: StateFlow<State> = _state.asStateFlow()
    private val _message = MutableStateFlow<String?>(null)
    val message: StateFlow<String?> = _message.asStateFlow()
    private var login: Job? = null

    private fun initial(): State = if (store.tokens() != null) State.SignedIn else if (store.app().isComplete) State.SignedOut else State.NotConfigured
    private fun client() = TraktClient(store.app(), web)
    val isSignedIn get() = store.tokens() != null
    fun app() = store.app()

    fun saveApp(a: TraktApp) { store.saveApp(a); if (store.tokens() == null) _state.value = if (a.isComplete) State.SignedOut else State.NotConfigured }

    fun beginSignIn() {
        _message.value = null; login?.cancel()
        login = scope.launch {
            try {
                val code = client().startDeviceLogin()
                _state.value = State.WaitingForCode(code.userCode, code.url)
                val end = System.currentTimeMillis() + code.expiresIn * 1000L
                while (System.currentTimeMillis() < end && isActive) {
                    delay(code.interval * 1000L)
                    client().pollDeviceToken(code)?.let { store.saveTokens(it); _state.value = State.SignedIn; _message.value = null; return@launch }
                }
                if (isActive) { _state.value = initial(); _message.value = "The code ran out. Start again." }
            } catch (e: CancellationException) { throw e } catch (e: Exception) { _state.value = initial(); _message.value = e.message }
        }
    }

    fun cancelSignIn() { login?.cancel(); _state.value = initial() }
    fun signOut() { login?.cancel(); store.saveTokens(null); _state.value = initial() }

    private suspend fun fresh(): TraktTokens {
        var t = store.tokens() ?: throw TraktException("Sign in to Trakt first.", TraktException.Kind.NOT_SIGNED_IN)
        if (t.isExpiring()) { t = client().refresh(t); store.saveTokens(t) }
        return t
    }

    /** Reports playback; never throws to the player. */
    fun scrobble(action: TraktClient.Scrobble, item: TraktItem, progress: Double) {
        if (!isSignedIn) return
        scope.launch {
            try { client().scrobble(action, item, progress, fresh()) }
            catch (e: TraktException) { if (e.kind == TraktException.Kind.NOT_SIGNED_IN) { signOut(); _message.value = "Trakt asked you to sign in again." } else _message.value = e.message }
            catch (e: Exception) { _message.value = e.message }
        }
    }

    suspend fun watchlist(): List<TraktListed> = client().watchlist(fresh())
}
