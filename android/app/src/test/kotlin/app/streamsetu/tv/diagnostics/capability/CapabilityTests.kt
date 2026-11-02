package app.streamsetu.tv.diagnostics.capability

import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class CapabilityTests {
    private fun lines(p: PlaybackCapabilityProfile) = CapabilityAnalysis.summary(p).associate { it.title to it.text }

    // ---- reporting

    @Test fun anUnknownInstanceBoundIsReportedAsUnknownNeverAsACount() {
        val p = profile(decoders = listOf(decoder(instances = null)))
        assertTrue(CapabilityReport.text(p).contains("reported upper bound of instances: unknown"))
        assertFalse(CapabilityReport.text(p).contains("can play"))
    }

    @Test fun emptyProfileLevelAndEncodingListsDoNotBreakAnything() {
        val p = profile(decoders = listOf(decoder(levels = emptyList())), audio = AudioFacts(listOf(route(encodings = emptyList())), null))
        assertTrue(lines(p).getValue("E-AC-3 direct playback").contains("Unknown on this Android version"))
        assertTrue(CapabilityReport.text(p).contains("none listed"))
    }

    @Test fun aSoftwareOnlyDecoderIsReportedAsSoftware() {
        val p = profile(decoders = listOf(decoder(name = "c2.android.hevc.decoder", hardware = false, software = true)))
        assertTrue(lines(p).getValue("HEVC Main10 4K60").contains("software decoder only"))
    }

    @Test fun aSecureOnlyDecoderIsNotAcceptedForAnOrdinaryStreamByTheAdvisorUnlessItReportsSecure() {
        val d = decoder(secure = Reported.SUPPORTED)
        val a = CapabilityAdvisor.advise(profile(decoders = listOf(d)), StreamFormat("mkv", "video/hevc", profile = 2, width = 3840, height = 2160, frameRate = 60f, secureRequired = true))
        assertEquals(SuggestedEngine.EXOPLAYER, a.engine); assertTrue(Reason.SECURE_DECODER_REQUIRED in a.reasons)
        val none = CapabilityAdvisor.advise(profile(decoders = listOf(decoder())), StreamFormat("mkv", "video/hevc", profile = 2, width = 3840, height = 2160, frameRate = 60f, secureRequired = true))
        assertNotEquals(Confidence.HIGH, none.confidence)
    }

    @Test fun aTunnelingOnlyDecoderIsReportedButTunnelingStaysDisabled() {
        val p = profile(decoders = listOf(decoder(tunneled = Reported.SUPPORTED)))
        val t = lines(p).getValue("Tunneling")
        assertTrue(t.contains("Reported by 1 decoder")); assertTrue(t.contains("Disabled"))
        assertTrue(lines(p).getValue("Frame-rate matching").contains("not changed here"))
    }

    @Test fun aDisplayThatReportsDolbyVisionDoesNotMakeTheDecoderReportIt() {
        val t = lines(profile(display = display(dv = Reported.SUPPORTED))).getValue("Dolby Vision")
        assertTrue(t, t.startsWith("Display: reported. Decoder: not reported")); assertTrue(t.contains("Playback verified: No."))
    }

    @Test fun aDecoderThatReportsDolbyVisionDoesNotMakeTheDisplayReportIt() {
        val dv = decoder(name = "dv", mime = DiagnosticFormats.DOLBY_VISION_MIME, levels = listOf(ProfileLevel(8, 512)), formats = emptyMap())
        val t = lines(profile(decoders = listOf(decoder(), dv), display = display(dv = Reported.UNSUPPORTED))).getValue("Dolby Vision")
        assertTrue(t, t.startsWith("Display: not reported. Decoder: reported (profile numbers 8)"))
    }

    @Test fun anAudioRouteWithDirectPlaybackAnswersFromAndroid13OnAndFromTheEncodingsBefore() {
        assertTrue(lines(profile(device = device(33))).getValue("E-AC-3 direct playback").contains("Direct playback: reported supported"))
        val old = profile(device = device(22), audio = AudioFacts(listOf(route(type = "TV or device speaker", encodings = listOf("PCM 16", "E-AC-3"))), null))
        assertTrue(lines(old).getValue("E-AC-3 direct playback").contains("lists E-AC-3 as an encoding"))
    }

    @Test fun anOldAndroidWithNothingReportedStillProducesEverySummaryLine() {
        val p = profile(decoders = emptyList(), device = device(22), display = DisplayFacts(null, emptyList(), Reported.NOT_AVAILABLE, Reported.NOT_AVAILABLE, Reported.NOT_AVAILABLE, Reported.NOT_AVAILABLE, null, null, null, "not available", 0, 0), audio = AudioFacts(emptyList(), null))
        assertEquals(5, CapabilityAnalysis.summary(p).size); assertTrue(lines(p).getValue("HEVC Main10 4K60").startsWith("Unknown"))
    }

    @Test fun theReportHoldsNoAddressLoginTitleOrAccount() {
        val text = CapabilityReport.text(profile(), listOf("H.264 1080p30 in MP4" to CapabilityAdvisor.advise(profile(), StreamFormat("mp4", "video/avc", width = 1920, height = 1080))))
        listOf("http", "://", "password", "token", "@", "user", "serial", "account").forEach { assertFalse("report mentions $it", text.contains(it, ignoreCase = true)) }
        assertTrue(text.contains("AFTMM"))
    }

    // ---- the service

    @Test fun theProfileIsReadOnceAndKeptUntilItIsAskedAgain() = runBlocking {
        val s = FakeSources(); val c = PlaybackCapabilities(s)
        c.get(); c.get(); c.get()
        assertEquals(1, s.calls)
        c.get(refresh = true); assertEquals(2, s.calls)
    }

    @Test fun anOutputChangeMakesTheNextReadFresh() = runBlocking {
        val s = FakeSources(profile(audio = AudioFacts(listOf(route(type = "TV or device speaker")), null))); val c = PlaybackCapabilities(s)
        assertEquals("TV or device speaker", ((c.get() as CapabilityResult.Ready).profile.audio.routes.single().type))
        s.profile = profile(audio = AudioFacts(listOf(route(type = "HDMI")), null)); c.invalidate()
        assertEquals("HDMI", ((c.get() as CapabilityResult.Ready).profile.audio.routes.single().type))
    }

    @Test fun theQueryRunsOffTheCallersThread() = runBlocking {
        val s = FakeSources(); PlaybackCapabilities(s).get()
        assertTrue(s.threads.toString(), s.threads.all { it.startsWith("DefaultDispatcher") }); assertFalse(s.threads.any { it == Thread.currentThread().name })
    }

    @Test fun aDeviceThatCannotBeReadIsAFailureWithAReasonAndNeverAnException() = runBlocking {
        val r = PlaybackCapabilities(FakeSources(failDevice = true)).get()
        assertTrue(r is CapabilityResult.Failed)
    }

    @Test fun oneFailingPartLeavesTheOthers() = runBlocking {
        val r = PlaybackCapabilities(FakeSources(failDecoders = true)).get() as CapabilityResult.Ready
        assertTrue(r.profile.decoders.isEmpty()); assertEquals("AFTMM", r.profile.device.model)
    }

    // ---- the advisor

    private val hevc4k = StreamFormat("mkv", "video/hevc", profile = 2, width = 3840, height = 2160, frameRate = 60f)

    @Test fun aHardwareDecoderThatReportsTheFormatGivesExoPlayerWithHighConfidence() {
        val a = CapabilityAdvisor.advise(profile(), hevc4k)
        assertEquals(SuggestedEngine.EXOPLAYER, a.engine); assertEquals(DecoderClass.HARDWARE_PREFERRED, a.decoderClass); assertEquals(Confidence.HIGH, a.confidence)
    }

    @Test fun aContainerTheNormalPathDoesNotReadGivesMpvWithMediumConfidence() {
        val a = CapabilityAdvisor.advise(profile(decoders = listOf(decoder(mime = "video/avc", levels = listOf(ProfileLevel(8, 512))))), StreamFormat("avi", "video/avc", profile = 8, width = 1024, height = 576, frameRate = 25f))
        assertEquals(SuggestedEngine.MPV, a.engine); assertEquals(Confidence.MEDIUM, a.confidence); assertTrue(Reason.CONTAINER_NOT_IN_EXOPLAYER_PATH in a.reasons)
    }

    @Test fun aFormatWithoutDetailsIsUnknownWithLowConfidence() {
        val a = CapabilityAdvisor.advise(profile(), StreamFormat(null, null, width = null, height = null))
        assertEquals(SuggestedEngine.UNKNOWN, a.engine); assertEquals(Confidence.LOW, a.confidence); assertEquals(listOf(Reason.FORMAT_DETAILS_MISSING), a.reasons)
    }

    @Test fun aDecoderWhoseReportsContradictEachOtherIsUnknownWithLowConfidence() {
        val liar = decoder(w = 1920, h = 1080, formats = mapOf("hevc-main10-2160p60" to Reported.SUPPORTED))
        val a = CapabilityAdvisor.advise(profile(decoders = listOf(liar)), hevc4k)
        assertEquals(SuggestedEngine.UNKNOWN, a.engine); assertEquals(Confidence.LOW, a.confidence); assertTrue(Reason.CONTRADICTORY_REPORTS in a.reasons)
    }

    @Test fun onlyASoftwareDecoderIsASoftwareFallbackWithAWarning() {
        val a = CapabilityAdvisor.advise(profile(decoders = listOf(decoder(name = "c2.android.hevc.decoder", hardware = false, software = true))), hevc4k)
        assertEquals(DecoderClass.SOFTWARE_FALLBACK, a.decoderClass); assertEquals(Confidence.MEDIUM, a.confidence); assertTrue(a.warnings.isNotEmpty())
    }

    @Test fun noDecoderInventoryIsUnknown() {
        assertEquals(SuggestedEngine.UNKNOWN, CapabilityAdvisor.advise(profile(decoders = emptyList()), hevc4k).engine)
    }

    @Test fun theAdvisorChangesNothingAndAnswersTheSameEveryTime() {
        val p = profile(); val before = p.copy()
        val a = CapabilityAdvisor.advise(p, hevc4k); val b = CapabilityAdvisor.advise(p, hevc4k)
        assertEquals(a, b); assertEquals(before, p)
    }

    @Test fun theAdvisorsAnswerCarriesNoAddressTitleOrProvider() {
        val a = CapabilityAdvisor.advise(profile(), hevc4k) { _, _ -> "c2.vendor.hevc.decoder" }
        val text = a.toString(); assertFalse(text.contains("http")); assertTrue(a.evidence.any { it.contains("Media3 would prefer") })
    }

    // ---- frame-rate matching, shown only

    @Test fun aRateThatIsAWholeMultipleOfTheContentRateFits() {
        assertTrue(CapabilityAnalysis.matches(24f, 24f)); assertTrue(CapabilityAnalysis.matches(24f, 48f)); assertTrue(CapabilityAnalysis.matches(23.976f, 119.88f)); assertTrue(CapabilityAnalysis.matches(25f, 50f))
        assertFalse(CapabilityAnalysis.matches(24f, 60f)); assertFalse(CapabilityAnalysis.matches(30f, 50f)); assertFalse(CapabilityAnalysis.matches(0f, 60f))
    }

    @Test fun aDisplayAlreadyOnAFittingRateNeedsNoSwitch() {
        val r = CapabilityAnalysis.frameRate(30f, mode(60f), listOf(mode(60f)))
        assertEquals(CapabilityAnalysis.FrameRateOutcome.NO_USEFUL_ALTERNATIVE, r.outcome); assertTrue(r.note.contains("already"))
    }

    @Test fun aFittingModeListedAsSeamlessIsAPossibleSeamlessMatch() {
        val cur = mode(60f, alt = listOf(48f)); val r = CapabilityAnalysis.frameRate(24f, cur, listOf(cur, mode(48f, id = 2)))
        assertEquals(CapabilityAnalysis.FrameRateOutcome.POSSIBLE_SEAMLESS_MATCH, r.outcome)
    }

    @Test fun aFittingModeNotListedAsSeamlessWouldNeedASwitchThatBlanksTheScreen() {
        val cur = mode(60f, alt = emptyList()); val r = CapabilityAnalysis.frameRate(24f, cur, listOf(cur, mode(48f, id = 2)))
        assertEquals(CapabilityAnalysis.FrameRateOutcome.NON_SEAMLESS_SWITCH_REQUIRED, r.outcome)
    }

    @Test fun noFittingModeIsNoUsefulAlternative() {
        val cur = mode(60f, alt = emptyList()); assertEquals(CapabilityAnalysis.FrameRateOutcome.NO_USEFUL_ALTERNATIVE, CapabilityAnalysis.frameRate(24f, cur, listOf(cur)).outcome)
    }

    @Test fun anAndroidThatCannotSayWhetherASwitchIsSeamlessIsUnknown() {
        val cur = mode(60f, alt = null); assertEquals(CapabilityAnalysis.FrameRateOutcome.UNKNOWN, CapabilityAnalysis.frameRate(24f, cur, listOf(cur, mode(48f, id = 2))).outcome)
        assertEquals(CapabilityAnalysis.FrameRateOutcome.UNKNOWN, CapabilityAnalysis.frameRate(null, cur, listOf(cur)).outcome)
    }
}
