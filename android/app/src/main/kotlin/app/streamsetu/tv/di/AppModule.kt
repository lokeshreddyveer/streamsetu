package app.streamsetu.tv.di

import android.content.Context
import app.streamsetu.core.data.db.AppDatabase
import app.streamsetu.core.data.repo.CatalogRepository
import app.streamsetu.core.data.repo.ParentalControls
import app.streamsetu.core.data.repo.SourceRepository
import app.streamsetu.core.data.repo.UserRepository
import app.streamsetu.core.model.*
import app.streamsetu.core.net.StreamResolver
import app.streamsetu.core.playback.PlaybackController
import app.streamsetu.core.security.CredentialStore
import app.streamsetu.core.security.KeystoreCredentialStore
import app.streamsetu.core.settings.AppSettings
import app.streamsetu.core.sync.EpgService
import app.streamsetu.core.sync.SyncService
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import javax.inject.Singleton

/** Where every long-lived object is built, once. The screens receive them through Hilt instead of reaching into a global. */
@Module
@InstallIn(SingletonComponent::class)
object AppModule {
    @Provides @Singleton fun appScope(): CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    @Provides @Singleton fun database(@ApplicationContext c: Context): AppDatabase = AppDatabase.open(c)
    @Provides @Singleton fun credentials(@ApplicationContext c: Context): CredentialStore = KeystoreCredentialStore(c)
    @Provides @Singleton fun sources(db: AppDatabase, credentials: CredentialStore) = SourceRepository(db, credentials)
    @Provides @Singleton fun library(db: AppDatabase, @ApplicationContext c: Context, scope: CoroutineScope) = app.streamsetu.core.data.repo.LibraryRepository(db, c, scope)
    @Provides @Singleton fun catalog(db: AppDatabase, library: app.streamsetu.core.data.repo.LibraryRepository, folders: app.streamsetu.core.data.repo.FolderRepository) = CatalogRepository(db, library, folders)
    @Provides @Singleton fun folders(db: AppDatabase, library: app.streamsetu.core.data.repo.LibraryRepository, parental: ParentalControls, settings: AppSettings) = app.streamsetu.core.data.repo.FolderRepository(db, library, parental) { if (settings.relockPolicy.value == "TEN") 10 * 60_000L else Long.MAX_VALUE }
    @Provides @Singleton fun browse(db: AppDatabase, library: app.streamsetu.core.data.repo.LibraryRepository, folders: app.streamsetu.core.data.repo.FolderRepository, @ApplicationContext c: Context) = app.streamsetu.core.data.repo.BrowseRepository(db, library, folders, c)
    @Provides @Singleton fun search(db: AppDatabase, library: app.streamsetu.core.data.repo.LibraryRepository, folders: app.streamsetu.core.data.repo.FolderRepository, @ApplicationContext c: Context) = app.streamsetu.core.data.repo.SearchRepository(db, library, folders, c)
    @Provides @Singleton fun user(db: AppDatabase) = UserRepository(db)
    @Provides @Singleton fun epg(db: AppDatabase) = EpgService(db)
    @Provides @Singleton fun parental(@ApplicationContext c: Context) = ParentalControls(c)
    @Provides @Singleton fun maintenance(@ApplicationContext c: Context, db: AppDatabase, sources: SourceRepository, library: app.streamsetu.core.data.repo.LibraryRepository) = app.streamsetu.core.data.repo.MaintenanceService(c, db, sources, library) { coil.Coil.imageLoader(c).memoryCache?.clear() }
    @Provides @Singleton fun collections(db: AppDatabase) = app.streamsetu.core.data.repo.CollectionRepository(db)
    @Provides @Singleton fun uiPrefs(@ApplicationContext c: Context) = app.streamsetu.core.settings.UiPrefs(c)
    @Provides @Singleton fun settings(@ApplicationContext c: Context) = AppSettings(c)
    @Provides @Singleton fun resolver(sources: SourceRepository, credentials: CredentialStore, @ApplicationContext c: Context) = StreamResolver(sources, credentials, c)
    @Provides @Singleton fun sync(db: AppDatabase, sources: SourceRepository, credentials: CredentialStore, resolver: StreamResolver, @ApplicationContext c: Context) =
        SyncService(db, sources, credentials, resolver) { uri -> c.contentResolver.openInputStream(android.net.Uri.parse(uri)) ?: error("That file could not be opened.") }

    @Provides @Singleton
    fun playback(@ApplicationContext c: Context, resolver: StreamResolver, settings: AppSettings, user: UserRepository): PlaybackController = PlaybackController(
        c, resolver, settings,
        onProgress = { item, pos, dur -> user.saveProgress(item.id, kindOf(item), (item as? EpisodePlayable)?.series?.id, pos, dur) },
        onStarted = { item -> user.recordPlay(item.id, kindOf(item), item.title) },
    )
}

fun kindOf(p: Playable) = when (p) {
    is ChannelPlayable -> ContentKind.CHANNEL
    is MoviePlayable -> ContentKind.MOVIE
    is EpisodePlayable -> ContentKind.EPISODE
    is SeriesFeature -> ContentKind.SERIES
    is CatchUpPlayable -> ContentKind.CHANNEL
}
