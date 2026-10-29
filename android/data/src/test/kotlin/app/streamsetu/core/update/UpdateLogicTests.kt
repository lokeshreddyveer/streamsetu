package app.streamsetu.core.update

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class UpdateLogicTests {
    private val sum = "f2a145fb480023fad5416df4ae5baf501520549503878c858d3272f797d0b1a2"

    private val json = """
    [
      {"tag_name":"mac-v2.2.7","draft":false,"prerelease":false,"body":"mac","assets":[{"name":"StreamSetu-2.2.7.dmg","browser_download_url":"https://x/mac.dmg","size":9}]},
      {"tag_name":"android-v0.6.10","draft":false,"prerelease":false,"body":"New\n`$sum`","assets":[
         {"name":"StreamSetu-FireTV-0.6.10.apk","browser_download_url":"https://x/tv.apk","size":100},
         {"name":"StreamSetu-Android-0.6.10.apk","browser_download_url":"https://x/phone.apk","size":100}]},
      {"tag_name":"android-v0.6.9","draft":false,"prerelease":false,"body":"old","assets":[{"name":"StreamSetu-FireTV-Android-0.6.9.apk","browser_download_url":"https://x/old.apk","size":50}]},
      {"tag_name":"android-v0.7.0","draft":true,"prerelease":false,"body":"draft","assets":[]},
      {"tag_name":"android-v0.8.0-beta","draft":false,"prerelease":true,"body":"beta","assets":[]},
      {"unrelated":true}
    ]
    """.trimIndent()

    @Test fun versionsCompareNumberByNumber() {
        assertTrue(UpdateLogic.isNewer("0.6.10", "0.6.9"))
        assertTrue(UpdateLogic.isNewer("1.0.0", "0.9.9"))
        assertTrue(UpdateLogic.isNewer("0.6.3", "0.6.2"))
        assertFalse(UpdateLogic.isNewer("0.6.2", "0.6.2"))
        assertFalse(UpdateLogic.isNewer("0.6.1", "0.6.2"))
        assertFalse(UpdateLogic.isNewer("0.6", "0.6.0"))          // a missing part is zero
    }

    @Test fun aLabelAfterTheNumbersIsIgnored() {
        assertFalse(UpdateLogic.isNewer("0.6.2-beta", "0.6.2"))
        assertTrue(UpdateLogic.isNewer("v0.6.3", "0.6.2"))
        assertEquals(listOf(0, 6, 2), UpdateLogic.parts("v0.6.2+build5"))
    }

    @Test fun onlyPublishedAndroidReleasesCount() {
        val r = UpdateLogic.parse(json)
        assertEquals(listOf("android-v0.6.10", "android-v0.6.9"), r.map { it.tag })
    }

    @Test fun theNewestVersionWinsNotTheFirstListed() {
        assertEquals("0.6.10", UpdateLogic.latest(UpdateLogic.parse(json))?.version)
        assertNull(UpdateLogic.latest(emptyList()))
    }

    @Test fun garbageGivesNoReleases() {
        assertTrue(UpdateLogic.parse("not json").isEmpty())
        assertTrue(UpdateLogic.parse("{}").isEmpty())
        assertTrue(UpdateLogic.parse("").isEmpty())
    }

    @Test fun aTvGetsTheFireTvFileAndAPhoneTheAndroidFile() {
        val r = UpdateLogic.parse(json).first()
        assertEquals("StreamSetu-FireTV-0.6.10.apk", UpdateLogic.pickAsset(r, television = true)?.name)
        assertEquals("StreamSetu-Android-0.6.10.apk", UpdateLogic.pickAsset(r, television = false)?.name)
    }

    @Test fun theTelevisionFileMayBeCalledStreamsetuTv() {
        val r = ReleaseInfo("2026.11.01", "0.20.0", "", listOf(
            ReleaseAsset("StreamSetu-Android-0.20.0.apk", "https://example.test/a", 1), ReleaseAsset("streamsetu-tv-0.20.0.apk", "https://example.test/t", 1)))
        assertEquals("streamsetu-tv-0.20.0.apk", UpdateLogic.pickAsset(r, television = true)?.name)
        assertEquals("StreamSetu-Android-0.20.0.apk", UpdateLogic.pickAsset(r, television = false)?.name)
    }

    @Test fun anOlderSingleFileReleaseServesBoth() {
        val old = UpdateLogic.parse(json).last()
        assertEquals("StreamSetu-FireTV-Android-0.6.9.apk", UpdateLogic.pickAsset(old, true)?.name)
        assertEquals("StreamSetu-FireTV-Android-0.6.9.apk", UpdateLogic.pickAsset(old, false)?.name)
    }

    @Test fun aReleaseWithoutAnApkOffersNothing() {
        assertNull(UpdateLogic.pickAsset(ReleaseInfo("android-v1.0.0", "1.0.0", "", emptyList()), true))
    }

    @Test fun theChecksumComesFromTheNotes() {
        val r = UpdateLogic.parse(json).first()
        assertEquals(sum, UpdateLogic.checksumFor(r.notes, "StreamSetu-Android-0.6.10.apk"))
    }

    @Test fun aChecksumOnTheFilesOwnLineWins() {
        val other = "a".repeat(64)
        val notes = "General: `$sum`\nStreamSetu-FireTV-1.apk  $other"
        assertEquals(other, UpdateLogic.checksumFor(notes, "StreamSetu-FireTV-1.apk"))
        assertEquals(sum, UpdateLogic.checksumFor(notes, "StreamSetu-Android-1.apk"))
    }

    @Test fun noChecksumMeansNoInstall() {
        assertNull(UpdateLogic.checksumFor("Nothing useful here, 12345", "x.apk"))
        assertNull(UpdateLogic.checksumFor("short abc123", "x.apk"))
        assertNotNull(UpdateLogic.checksumFor(sum.uppercase(), "x.apk"))
    }

    @Test fun oneReleaseForEveryAppIsReadByItsApkNames() {
        val json = """[{"tag_name":"2026.10.14","draft":false,"prerelease":false,"body":"x","assets":[
            {"name":"StreamSetu-2.4.0.dmg","browser_download_url":"https://x/mac.dmg","size":9},
            {"name":"StreamSetu-FireTV-0.9.1.apk","browser_download_url":"https://x/tv.apk","size":9},
            {"name":"StreamSetu-Android-0.9.1.apk","browser_download_url":"https://x/ph.apk","size":9}]}]"""
        val r = UpdateLogic.parse(json).single()
        assertEquals("0.9.1", r.version)
        assertEquals("https://x/tv.apk", UpdateLogic.pickAsset(r, television = true)?.url)
        assertEquals("https://x/ph.apk", UpdateLogic.pickAsset(r, television = false)?.url)
    }
}
