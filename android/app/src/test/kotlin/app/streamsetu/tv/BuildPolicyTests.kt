package app.streamsetu.tv

import org.junit.Assert.*
import org.junit.Test
import java.io.File

/** The build's network and store policy, read from the files that define it. */
class BuildPolicyTests {
    private val app = listOf("src/main", "app/src/main").map { File(it).absoluteFile }.first { it.exists() }
    private val gradle = app.parentFile.parentFile.resolve("build.gradle.kts").readText()
    private val manifest = app.resolve("AndroidManifest.xml").readText()
    private val nsc = app.resolve("res/xml/network_security_config.xml").readText()

    @Test fun playbackOfPlainHttpStreamsStaysAllowedButTheAppsOwnServicesAreHttpsOnly() {
        assertTrue(manifest.contains("android:networkSecurityConfig=\"@xml/network_security_config\"")); assertTrue(manifest.contains("android:usesCleartextTraffic=\"true\""))
        assertTrue("base config keeps cleartext for provider streams", Regex("""<base-config cleartextTrafficPermitted="true"""").containsMatchIn(nsc))
        val own = nsc.substringAfter("<domain-config cleartextTrafficPermitted=\"false\">").substringBefore("</domain-config>")
        for (d in listOf("themoviedb.org", "tmdb.org", "fanart.tv", "thetvdb.com", "tvmaze.com", "opensubtitles.com", "trakt.tv", "api.github.com", "iptv-org.github.io")) assertTrue("$d must be https only", own.contains(">$d<"))
        for (d in listOf("raw.githubusercontent.com", "githubusercontent.com", ">github.com<")) assertFalse("$d must stay open to a person's own playlist", own.contains(d))
    }

    @Test fun theInstallPermissionBelongsToTheGithubBuildAndIsLeftOutOfAStoreBuild() {
        assertTrue(manifest.contains("\${installPackagesPermission}")); assertFalse("fixed permission left in the manifest", manifest.contains("android:name=\"android.permission.REQUEST_INSTALL_PACKAGES\""))
        assertTrue(gradle.contains("\"installPackagesPermission\"] = if (storeBuild) \"android.permission.ACCESS_NETWORK_STATE\" else \"android.permission.REQUEST_INSTALL_PACKAGES\""))
        assertTrue("a store build has no self update", gradle.contains("!project.hasProperty(\"storeBuild\")"))
    }

    @Test fun theStoreFlagIsOffByDefaultAndHidesTheStalkerType() {
        assertFalse("the current build is not a store build", BuildConfig.STORE_BUILD)
        assertTrue(gradle.contains("project.hasProperty(\"storeBuild\")"))
        for (f in listOf("ui/screens/library/LibraryScreens.kt", "ui/phone/PhoneChooser.kt", "ui/screens/library/StartScreens.kt")) assertTrue(f, app.resolve("kotlin/app/streamsetu/tv/$f").readText().contains("STORE_BUILD"))
    }
}
