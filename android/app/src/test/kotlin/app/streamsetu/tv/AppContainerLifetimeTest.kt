package app.streamsetu.tv

import android.content.Context
import android.net.ConnectivityManager
import androidx.test.core.app.ApplicationProvider
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.android.testing.HiltAndroidRule
import dagger.hilt.android.testing.HiltAndroidTest
import dagger.hilt.android.testing.HiltTestApplication
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * AppContainer joins everything the app does for the whole process (search context wiring, the network watcher, downloads, the player). It has to exist once:
 * the Application, every Activity (also a recreated one) and every Service must be handed the same object. This runs the real Hilt graph and the real
 * MainActivity, PlaybackService and DownloadService, and checks that.
 *
 * "Initialization ran once" is counted from outside the app: AppContainer's init block registers exactly one network callback with the system, so the number of
 * callbacks the system holds is the number of containers that were built. Nothing in the app is there only for this test.
 */
@HiltAndroidTest
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = HiltTestApplication::class)
class AppContainerLifetimeTest {
    @get:Rule val hilt = HiltAndroidRule(this)

    private val app get() = ApplicationProvider.getApplicationContext<HiltTestApplication>()

    private fun applicationContainer(): AppContainer = EntryPointAccessors.fromApplication(app, SyncEntryPoint::class.java).container()

    /** How many containers have run their init block: each one registers one callback with the system's connectivity service. */
    private fun containersBuilt(): Int =
        shadowOf(app.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager).networkCallbacks.size

    @Test fun theApplicationAndEveryComponentShareOneContainer() {
        hilt.inject()
        val fromApplication = applicationContainer()

        val activity = Robolectric.buildActivity(MainActivity::class.java).create()
        assertSame("Activity", fromApplication, activity.get().container)

        val playback = Robolectric.buildService(PlaybackService::class.java).create()
        assertSame("PlaybackService", fromApplication, playback.get().container)

        val downloads = Robolectric.buildService(DownloadService::class.java).create()
        assertSame("DownloadService", fromApplication, downloads.get().container)

        // What the container owns is shared too: a screen and the download service see the same list of saved titles, not two copies.
        assertSame(fromApplication.downloads, downloads.get().container.downloads)
        assertSame(fromApplication.profiles, activity.get().container.profiles)
    }

    @Test fun recreatingTheActivityKeepsTheContainer() {
        hilt.inject()
        val before = applicationContainer()
        val controller = Robolectric.buildActivity(MainActivity::class.java).create()
        val first = controller.get()
        assertSame(before, first.container)
        val builtBefore = containersBuilt()

        val second = controller.recreate().get()          // the system destroys the Activity and builds a new one, as on rotation or a theme change

        assertNotSame("a new Activity object", first, second)
        assertSame("the same container after recreation", before, second.container)
        assertEquals("recreating built another container", builtBefore, containersBuilt())
    }

    @Test fun startingServicesDoesNotBuildAnotherContainer() {
        hilt.inject()
        val before = applicationContainer()
        val builtBefore = containersBuilt()

        Robolectric.buildService(PlaybackService::class.java).create()
        Robolectric.buildService(DownloadService::class.java).create().startCommand(0, 1)

        assertEquals("starting a service built another container", builtBefore, containersBuilt())
        assertSame(before, applicationContainer())
    }

    @Test fun appWideInitializationRunsExactlyOnce() {
        hilt.inject()
        // The player (one per process, also built by Hilt) watches the network as well, so it is created first and the container is counted on top of it.
        EntryPointAccessors.fromApplication(app, PlayerEntryPoint::class.java).playback()
        val withPlayerOnly = containersBuilt()

        applicationContainer()
        assertEquals("the first request builds one container", withPlayerOnly + 1, containersBuilt())

        repeat(3) { applicationContainer() }
        Robolectric.buildActivity(MainActivity::class.java).create().recreate()
        Robolectric.buildService(PlaybackService::class.java).create()
        Robolectric.buildService(DownloadService::class.java).create()

        assertEquals("one container, one init, however many components asked for it", withPlayerOnly + 1, containersBuilt())
    }

    @dagger.hilt.EntryPoint
    @dagger.hilt.InstallIn(dagger.hilt.components.SingletonComponent::class)
    interface PlayerEntryPoint { fun playback(): app.streamsetu.core.playback.PlaybackController }
}
