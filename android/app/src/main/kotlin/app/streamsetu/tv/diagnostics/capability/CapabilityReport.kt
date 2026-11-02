package app.streamsetu.tv.diagnostics.capability

/**
 * The text a person can save and send. It has the device model, Android version, decoder, display and audio facts, and nothing that names a provider, a title, a login, an address,
 * a query or an account. Every statement is "reported"; none is "verified".
 */
object CapabilityReport {
    fun text(p: PlaybackCapabilityProfile, advice: List<Pair<String, Advice>> = emptyList()): String = buildString {
        appendLine("StreamSetu playback capabilities (what this device reports; nothing here is verified by playing)")
        appendLine("Device: ${p.device.manufacturer} ${p.device.model} (${p.device.device}), Android ${p.device.release} (API ${p.device.sdk})")
        appendLine("Memory: class ${p.memory.memoryClassMb} MB, large class ${p.memory.largeMemoryClassMb} MB, low-RAM device ${p.memory.lowRamDevice}, system RAM ${p.memory.totalMb} MB (${p.memory.availableMb} MB free)")
        appendLine()
        appendLine("Summary")
        CapabilityAnalysis.summary(p).forEach { appendLine("  ${it.title}: ${it.text}") }
        appendLine()
        appendLine("Display")
        val d = p.display
        appendLine("  Current mode: ${d.current?.let { "${it.width}x${it.height} at ${"%.3f".format(it.refreshRate)} Hz" } ?: "unknown"}; the interface is ${d.uiWidth}x${d.uiHeight}")
        appendLine("  Modes: " + d.modes.joinToString("; ") { "${it.width}x${it.height} ${"%.2f".format(it.refreshRate)} Hz" }.ifBlank { "none reported" })
        appendLine("  Other refresh rates reported: ${d.alternativeRefreshRatesReported.label}")
        appendLine("  HDR (${d.hdrSource}): HDR10 ${d.hdr10.label}; HDR10+ ${d.hdr10Plus.label}; HLG ${d.hlg.label}; Dolby Vision ${d.dolbyVision.label}")
        if (d.maxLuminance != null) appendLine("  Luminance: max ${d.maxLuminance}, average max ${d.maxAverageLuminance ?: "unknown"}, min ${d.minLuminance ?: "unknown"} nits")
        appendLine()
        appendLine("Audio outputs")
        if (p.audio.routes.isEmpty()) appendLine("  none reported")
        p.audio.routes.forEach { r ->
            appendLine("  ${r.type}${if (r.product.isNotBlank()) " (${r.product})" else ""}: encodings ${r.encodings.joinToString(", ").ifBlank { "none listed" }}; channels ${r.channelCounts.joinToString(", ").ifBlank { "unknown" }}; rates ${r.sampleRates.joinToString(", ").ifBlank { "unknown" }}")
        }
        p.audio.direct?.let { m -> appendLine("  Direct playback by the current route: " + m.entries.joinToString("; ") { "${it.key} ${it.value.label}" }) } ?: appendLine("  Direct playback: ${Reported.NOT_AVAILABLE.label}")
        appendLine()
        appendLine("Video decoders (${p.decoders.size})")
        p.decoders.sortedWith(compareBy({ it.mime }, { !it.isHardware }, { it.name })).forEach { x ->
            appendLine("  ${x.mime} ${x.name} [${if (x.isHardware) "hardware" else "software"}${if (x.secure == Reported.SUPPORTED) ", secure" else ""}${if (x.tunneled == Reported.SUPPORTED) ", tunneled" else ""}${if (x.adaptive == Reported.SUPPORTED) ", adaptive" else ""}] " +
                "up to ${x.maxWidth ?: "?"}x${x.maxHeight ?: "?"} at ${x.maxFrameRate ?: "?"} fps; reported upper bound of instances: ${x.maxInstances ?: "unknown"}; profiles ${x.profileLevels.size}")
            x.formats.forEach { (id, r) -> appendLine("      ${DiagnosticFormats.byId(id)?.label ?: id}: ${r.label}") }
        }
        if (advice.isNotEmpty()) {
            appendLine(); appendLine("Advisor (suggestion only; nothing uses it)")
            advice.forEach { (label, a) -> appendLine("  $label: ${a.engine.label}, ${a.decoderClass.label}, confidence ${a.confidence.label}. " + a.reasons.joinToString(" ") { it.text }) }
        }
    }
}
