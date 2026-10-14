package app.streamsetu.tv.ui.screens

import androidx.lifecycle.ViewModel
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import androidx.lifecycle.viewModelScope
import app.streamsetu.core.data.repo.SearchResults
import app.streamsetu.core.model.*
import app.streamsetu.core.data.repo.UserRepository
import app.streamsetu.tv.AppContainer
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import app.streamsetu.core.sync.upcoming

class SeriesDetailViewModel(private val c: AppContainer, val series: Series) : ViewModel() {
    val episodes: StateFlow<List<Episode>> = c.catalog.episodes(series.id).stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    private val _loading = MutableStateFlow(true)
    val loading: StateFlow<Boolean> = _loading
    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error
    val progress: StateFlow<Map<String, WatchProgress>> = c.user.allProgress().map { m -> m.filterValues { it.seriesId == series.id } }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyMap())

    init {
        viewModelScope.launch {
            runCatching { c.sync.loadEpisodes(series) }.onFailure { _error.value = "The episodes could not be loaded. ${it.message.orEmpty()}" }
            _loading.value = false
        }
    }
}

