package app.streamsetu.tv.diagnostics.capability

internal fun device(sdk: Int = 30) = DeviceIdentity(sdk, "11", "Amazon", "AFTMM", "mantis", true)
internal fun memory() = MemoryFacts(256, 512, false, 2048, 900)
internal fun mode(rate: Float = 60f, w: Int = 3840, h: Int = 2160, alt: List<Float>? = null, hdr: List<String>? = null, id: Int = 1) = DisplayMode(id, w, h, rate, alt, hdr)
internal fun display(current: DisplayMode? = mode(), modes: List<DisplayMode> = listOf(mode()), dv: Reported = Reported.UNSUPPORTED, hdr10: Reported = Reported.SUPPORTED) =
    DisplayFacts(current, modes, hdr10, Reported.UNSUPPORTED, Reported.SUPPORTED, dv, 1000f, 800f, 0.05f, "display", 1920, 1080)
internal fun route(type: String = "HDMI", encodings: List<String> = listOf("PCM 16", "AC-3", "E-AC-3")) = AudioRoute(type, "TV", encodings, listOf(2, 6), listOf(48000), emptyList(), emptyList())
internal fun decoder(
    name: String = "c2.vendor.hevc.decoder", mime: String = "video/hevc", hardware: Boolean? = true, software: Boolean? = false, levels: List<ProfileLevel> = listOf(ProfileLevel(2, 1)),
    w: Int? = 4096, h: Int? = 2160, fps: Int? = 120, instances: Int? = 4, secure: Reported = Reported.UNSUPPORTED, tunneled: Reported = Reported.UNSUPPORTED,
    formats: Map<String, Reported> = mapOf("hevc-main10-2160p60" to Reported.SUPPORTED),
) = DecoderInfo(name, mime, hardware, software, false, false, levels, 16, w, 16, h, 1, fps, 1, 80_000_000, instances, Reported.SUPPORTED, secure, tunneled, formats)

internal fun profile(
    decoders: List<DecoderInfo> = listOf(decoder()), display: DisplayFacts = display(), audio: AudioFacts = AudioFacts(listOf(route()), mapOf("E-AC-3" to Reported.SUPPORTED)), device: DeviceIdentity = device(),
) = PlaybackCapabilityProfile(device, memory(), display, audio, decoders, 0L)

internal class FakeSources(
    var profile: PlaybackCapabilityProfile = profile(), var failDevice: Boolean = false, var failDecoders: Boolean = false,
) : CapabilitySources {
    var calls = 0; val threads = mutableListOf<String>()
    private fun seen() { threads += Thread.currentThread().name }
    override fun device(): DeviceIdentity { calls++; seen(); if (failDevice) error("device"); return profile.device }
    override fun memory() = profile.memory
    override fun display() = profile.display
    override fun audio() = profile.audio
    override fun decoders(): List<DecoderInfo> { if (failDecoders) error("decoders"); return profile.decoders }
}
