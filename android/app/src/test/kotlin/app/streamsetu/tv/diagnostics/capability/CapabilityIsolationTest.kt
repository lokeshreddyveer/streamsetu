package app.streamsetu.tv.diagnostics.capability

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The capability package may only read. This fails the moment any file in it builds a player, a decoder, an audio track or a surface, switches a display mode, sets a frame rate, or
 * depends on the code that chooses or runs an engine, and it fails if the real playback code starts depending on the capability package.
 */
class CapabilityIsolationTest {
    private val root = listOf("src/main/kotlin", "app/src/main/kotlin").map { File(it) }.first { it.exists() }
    private val capabilityDir = File(root, "app/streamsetu/tv/diagnostics/capability")

    private val forbiddenInCapability = listOf(
        "app.streamsetu.core.playback", "PlaybackController", "EnginePreference", "EngineKind", "ExoPlayer.Builder", "androidx.media3.exoplayer.ExoPlayer", "Mpv", "mpv.",
        "AudioTrack(", "AudioTrack.Builder", "createDecoderByType", "createByCodecName", "createCodecByName", "SurfaceView", "TextureView", "setFrameRate(", "setPreferredDisplayModeId", "preferredDisplayModeId",
        "setTunnelingEnabled", "setTunneling", "StreamResolver", "SourceRepository", "AppContainer",
    )

    @Test fun theCapabilityPackageNeverBuildsPlaysOrChangesAnything() {
        val files = capabilityDir.listFiles { f -> f.extension == "kt" }.orEmpty()
        assertTrue("the package was not found at $capabilityDir", files.isNotEmpty())
        val problems = files.flatMap { f -> f.readLines().withIndex().filter { (_, l) -> !l.trimStart().startsWith("*") && !l.trimStart().startsWith("//") && !l.trimStart().startsWith("/**") }
            .flatMap { (i, l) -> forbiddenInCapability.filter { l.contains(it) }.map { "${f.name}:${i + 1} uses $it" } } }
        assertTrue(problems.joinToString("\n"), problems.isEmpty())
    }

    @Test fun onlyTheMedia3AdapterTouchesMedia3() {
        val others = capabilityDir.listFiles { f -> f.extension == "kt" && f.name != "Media3DecoderAdapter.kt" }.orEmpty().filter { it.readText().contains("androidx.media3") }
        assertTrue(others.joinToString { it.name }, others.isEmpty())
    }

    @Test fun theRealPlaybackAndEngineChoiceNeverUseTheCapabilityPackage() {
        val users = root.walkTopDown().filter { it.extension == "kt" && !it.path.contains("/diagnostics/capability/") && !it.path.contains("ui/screens/settings/CapabilitiesUi.kt") }
            .filter { it.readText().contains("tv.diagnostics.capability") }.map { it.name }.toList()
        assertTrue("code outside Diagnostics uses the capability package: $users", users.isEmpty())
    }
}
