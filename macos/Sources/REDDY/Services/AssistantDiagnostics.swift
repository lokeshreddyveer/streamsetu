import Foundation

/// A finding the assistant can state: what happened, why, what the app saw, and one next step. Worked out from the app's own numbers, not guessed by a model; a model, when there is one, only
/// puts it into friendlier words.
struct AssistantFinding: Sendable, Equatable {
    /// Whose problem it most likely is. Keeps "the app is broken" apart from "the provider is down" and "the network is blocking it".
    enum Cause: String, Sendable { case app, provider, network, credentials, format, guide, outage, device, unknown, fine }
    var what: String
    var why: String
    var cause: Cause
    var observed: [String] = []
    var next: [String] = []
    /// Offers the assistant makes as buttons ("retry", "engine:mpv", "sync_guide"…).
    var actions: [String] = []

    /// The answer, in the shape the person reads: short and operational.
    var text: String {
        var t = what
        if !why.isEmpty { t += "\n\n" + why }
        if !observed.isEmpty { t += "\n\nWhat StreamSetu saw: " + observed.joined(separator: "; ") + "." }
        if !next.isEmpty { t += "\n\nTry this next:\n" + next.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n") }
        return t
    }
}

/// The numbers the playback diagnosis reads, gathered from the player.
struct PlaybackEvidence: Sendable {
    var playing = false
    var live = false
    var state = "idle"
    var failure: PlaybackError?
    var failureIsRecent = false
    var engine: PlaybackEngineKind = .avPlayer
    var container: StreamContainer = .unknown
    var enginePreference: PlaybackEnginePreference = .automatic
    var availableEngines: Set<PlaybackEngineKind> = [.avPlayer]
    var stalls = 0
    var stallSeconds = 0.0
    var bufferedAhead = 0.0
    var droppedFrames = 0
    var observedMbps = 0.0
    var streamMbps = 0.0
    var width = 0, height = 0
    var online = true
    var timeline: [String] = []
    var hardwareDecoding = "Automatic"
    var buffering = "Automatic"
}

enum AssistantDiagnostics {
    // MARK: playback

    static func playback(_ e: PlaybackEvidence) -> AssistantFinding {
        var observed: [String] = []
        if e.playing || e.failure != nil { observed.append("engine \(e.engine.rawValue)") }
        if e.container != .unknown { observed.append("stream type \(e.container.rawValue.uppercased())") }
        if e.width > 0 { observed.append("picture \(e.width)×\(e.height)") }
        if e.stalls > 0 { observed.append("\(e.stalls) stall\(e.stalls == 1 ? "" : "s") (\(Int(e.stallSeconds)) s)") }
        if e.droppedFrames > 0 { observed.append("\(e.droppedFrames) dropped frames") }
        if e.observedMbps > 0 { observed.append(String(format: "download speed seen %.1f Mbit/s", e.observedMbps)) }
        if !e.timeline.isEmpty { observed.append("recent: " + e.timeline.suffix(5).joined(separator: " → ")) }

        if !e.online {
            return .init(what: "This device is offline.", why: "Nothing can play until it is back on a network. This is a network problem, not a StreamSetu or provider one.", cause: .network, observed: observed,
                         next: ["Reconnect to Wi-Fi or mobile data, then retry."], actions: ["retry"])
        }

        // 1. A failure the player reported
        if let f = e.failure, e.failureIsRecent || !e.playing {
            var out = AssistantFinding(what: f.message, why: "", cause: .unknown, observed: observed, next: [f.advice], actions: ["retry"])
            switch f.kind {
            case .nameLookup:
                out.cause = .network
                out.why = "The server's name could not be looked up. Your internet may be fine: a DNS filter or ad-blocker on this network is the usual cause."
                out.next = ["Turn off the DNS filter (Pi-hole, AdGuard, NextDNS, a DNS profile or Private Relay) for this network, or allow the provider's names.", "Retry the channel."]
            case .network:
                out.cause = .network
                out.why = "The request never got through, so the connection to the provider failed on this device's side."
                out.next = ["Check Wi-Fi or mobile data and that a VPN or proxy is not blocking it.", "Retry. If other apps work, the provider's server may be down."]
            case .authorization:
                out.cause = .credentials
                out.why = "The provider answered but refused the request. That means the login is wrong or expired, or the account is already streaming on too many devices."
                out.next = ["Open the playlist's login and check the username and password with your provider.", "Close the stream on your other devices, then retry."]
                out.actions = ["retry", "open_sources"]
            case .unsupportedFormat:
                out.cause = .format
                let other: PlaybackEngineKind = e.engine == .mpv ? .avPlayer : .mpv
                out.why = "This stream's format is not one the \(e.engine.rawValue) engine can open."
                if e.availableEngines.contains(other) { out.next = ["Switch to \(other.rawValue) and retry (Automatic normally does this by itself once)."]; out.actions = ["engine:\(other == .mpv ? "mpv" : "avPlayer")"] }
                else { out.next = ["Only one player engine is available on this device, so this format cannot be played here. Try another version of the title."] }
            case .timeout:
                out.cause = .provider
                out.why = "The provider was slow to start the stream. Live streams can take a while; a busy or distant server is the usual cause."
                out.next = ["Retry once.", "If it keeps timing out, set Buffering to Large buffer in Settings → Playback, or try another channel from the same playlist."]
            case .providerBusy:
                out.cause = .provider
                out.why = "The provider accepted the request but sent no video. Many providers allow one stream per account at a time."
                out.next = ["Stop streams on other devices, then retry.", "If other titles play, this one is unavailable at the provider right now."]
            case .providerUnavailable:
                out.cause = .outage
                out.why = "The stream could not be reached. The channel may be offline at the provider."
                out.next = ["Try another channel from the same playlist: if those work, this channel is down.", "Try again later."]
            case .notFound:
                out.cause = .provider
                out.why = "The provider no longer has this stream, or renamed it."
                out.next = ["Refresh the playlist (Settings → Library → Manage), then find it again."]
                out.actions = ["refresh"]
            case .engineUnavailable:
                out.cause = .app
                out.why = "The player engine you chose is not available on this device."
                out.next = ["Set the engine back to Automatic (Settings → Playback → Player engine). That is saved for the next streams.", "Then try the stream again."]
                out.actions = ["engine:auto", "retry"]
            case .unknown:
                out.cause = .unknown
                out.why = "The player did not say why. Try the other engine, and another channel to see whether it is this one stream."
                let other: PlaybackEngineKind = e.engine == .mpv ? .avPlayer : .mpv
                if e.availableEngines.contains(other) { out.actions = ["retry", "engine:\(other == .mpv ? "mpv" : "avPlayer")"] }
            }
            return out
        }

        guard e.playing else {
            return .init(what: "Nothing is playing right now.", why: "Start a channel or title and ask again, and I can look at how the stream is doing.", cause: .fine)
        }

        // 2. Playing, but poorly
        if e.stalls >= 3 || (e.live && e.bufferedAhead < 2 && e.stalls >= 1) {
            var f = AssistantFinding(what: "This stream keeps stopping to buffer.", why: "", cause: .unknown, observed: observed, next: [], actions: ["retry"])
            if e.observedMbps > 0, e.streamMbps > 0, e.observedMbps < e.streamMbps * 1.2 {
                f.cause = .network
                f.why = String(format: "The stream needs about %.1f Mbit/s and the connection is delivering about %.1f Mbit/s, so the player runs out of video. That points to the network or the provider's server speed, not to StreamSetu.", e.streamMbps, e.observedMbps)
                f.next = ["Move closer to the router or use a wired connection, and pause other downloads.", "Set Buffering to Large buffer in Settings → Playback → Buffering.", "If a lower-quality version of the channel exists, use that one."]
            } else if e.droppedFrames > 120 {
                f.cause = .device
                f.why = "Frames are being dropped while data keeps arriving, so this device is struggling to decode the picture rather than the network failing."
                f.next = e.hardwareDecoding == "Software decoding" ? ["Set Hardware decoding to Automatic in Settings → Playback → Video."] : ["Try the other player engine.", "Close heavy apps, or choose a lower-quality version of the channel."]
            } else {
                f.cause = .provider
                f.why = "Data is arriving, but the source is not keeping a steady connection. That usually means the provider's server is overloaded or throttling this stream."
                var steps = ["Test another channel from the same playlist. If those are fine, this stream is the problem."]
                let other: PlaybackEngineKind = e.engine == .mpv ? .avPlayer : .mpv
                if e.availableEngines.contains(other) { steps.insert("Switch from \(e.engine.rawValue) to \(other.rawValue) and retry.", at: 0); f.actions.append("engine:\(other == .mpv ? "mpv" : "avPlayer")") }
                steps.append("Set Buffering to Large buffer (Settings → Playback → Buffering).")
                f.next = steps
            }
            return f
        }
        if e.droppedFrames > 200 {
            return .init(what: "The picture is dropping frames.", why: "The network is fine, but this device is not keeping up with decoding.", cause: .device, observed: observed,
                         next: ["Try the other player engine.", "Set Hardware decoding to Automatic (Settings → Playback → Video)."])
        }
        if e.state.contains("buffering") || e.state.contains("reconnecting") {
            return .init(what: "The stream is starting or reconnecting.", why: "It has not had a chance to settle yet. Live streams can take several seconds to begin.", cause: .fine, observed: observed, next: ["Give it ten seconds, then ask again."])
        }
        return .init(what: "The stream looks healthy.", why: "It is playing with \(e.stalls) stall\(e.stalls == 1 ? "" : "s") and no sign of trouble.", cause: .fine, observed: observed,
                     next: e.stalls > 0 ? ["If you still see hiccups, say what you see (picture, sound or buffering) and I will dig in."] : [])
    }

    // MARK: engine advice

    /// Which engine suits a stream, and why. Mirrors how Automatic chooses, so the advice matches what the app would do.
    static func engineAdvice(container: StreamContainer, current: PlaybackEngineKind, preference: PlaybackEnginePreference, available: Set<PlaybackEngineKind>, hadFormatError: Bool) -> AssistantFinding {
        let auto = EngineSelector.select(container: container, preference: .automatic, available: available)
        var why: String
        switch container {
        case .hls, .mp4: why = "HLS and MP4 are what Apple's player does best, with hardware decoding."
        case .mpegTS: why = "Raw MPEG-TS is read directly by MPV where it is available; otherwise Apple's player plays it through a local bridge."
        case .mkv, .rtsp, .dash: why = "\(container.rawValue.uppercased()) is a format Apple's player cannot open natively, so MPV is the right engine when it is available."
        case .unknown: why = "The format is not known yet, so Automatic starts with Apple's player and tries the other engine once if it fails."
        }
        var next = ["Leave Settings → Playback → Player engine on Automatic: it picks \(auto.rawValue) for this stream."]
        var actions: [String] = []
        if current != auto, available.contains(auto) { next.append("This stream is on \(current.rawValue) now; switching to \(auto.rawValue) is the better match."); actions.append("engine:\(auto == .mpv ? "mpv" : "avPlayer")") }
        if hadFormatError { next.append("A format error was reported, so the other engine is worth trying once.") }
        if available.count == 1 { why += " Only \(available.first!.rawValue) is available on this device." }
        return .init(what: "Recommended engine: \(auto.rawValue).", why: why, cause: .fine, observed: ["this stream: \(container.rawValue.uppercased())", "now using \(current.rawValue)", "your setting: \(preference.rawValue)"], next: next, actions: actions)
    }

    // MARK: guide

    struct GuideEvidence: Sendable {
        var source = ""
        var hasGuideAddress = false
        var channels = 0
        var programmes = 0
        var mapped = 0
        var lastUpdate: Date?
        var refreshSetting = ""
        var shiftMinutes = 0
        var sourceKind = ""
    }

    static func guide(_ g: GuideEvidence, now: Date = Date()) -> AssistantFinding {
        var observed = ["playlist “\(g.source)”", "\(g.programmes) programmes", "\(g.mapped) of \(g.channels) guide channels matched to channels"]
        if let d = g.lastUpdate { observed.append("guide last updated \(Self.ago(d, now))") } else { observed.append("guide never downloaded") }
        if !g.hasGuideAddress && g.programmes == 0 {
            return .init(what: "The guide is empty because this playlist has no guide address.", why: "StreamSetu can still play its channels. The guide is downloaded from an XMLTV address the provider supplies.", cause: .guide, observed: observed,
                         next: ["Open the playlist in Settings → Library → Manage and add its guide (XMLTV) address if your provider gave you one.", "Then refresh the guide."], actions: ["open_sources"])
        }
        if g.programmes == 0 {
            return .init(what: "The guide is empty: the playlist has a guide address, but no programmes came back.", why: "Either it has not been downloaded yet, or the provider returned nothing. Playback is not affected.", cause: .guide, observed: observed,
                         next: ["Run a guide refresh.", "If it stays empty, check with the provider that the guide address works."], actions: ["sync_guide"])
        }
        if g.channels > 0, g.mapped * 4 < g.channels {
            return .init(what: "Most channels have no guide entries.", why: "The guide has data, but only \(g.mapped) of \(g.channels) guide channels match your channels by name or id. That is a naming mismatch at the provider, not a download problem.", cause: .provider, observed: observed,
                         next: ["Open a channel's menu and match its guide entry by hand if it is wrong.", "Ask the provider for a guide that uses the same channel ids as the playlist."])
        }
        if let d = g.lastUpdate, now.timeIntervalSince(d) > 3 * 86400 {
            return .init(what: "The guide is out of date.", why: "It was last downloaded \(Self.ago(d, now)). Programmes shown may have already aired.", cause: .guide, observed: observed, next: ["Run a guide refresh.", "Check Settings → Library → Programme guide: \(g.refreshSetting.isEmpty ? "the refresh schedule" : "it refreshes " + g.refreshSetting.lowercased())."], actions: ["sync_guide"])
        }
        if g.shiftMinutes == 0 {
            return .init(what: "The guide looks healthy.", why: "It has \(g.programmes) programmes and was updated \(g.lastUpdate.map { Self.ago($0, now) } ?? "recently"). If the times look hours off, the provider's guide is in another time zone.", cause: .fine, observed: observed,
                         next: ["If times are wrong, shift this playlist's guide in its settings (Playlists → its Connection section)."])
        }
        return .init(what: "The guide looks healthy.", why: "It has \(g.programmes) programmes. A \(g.shiftMinutes)-minute shift is applied to this playlist.", cause: .fine, observed: observed)
    }

    // MARK: source health

    struct SourceEvidence: Sendable {
        var name = ""
        var kind = ""
        var enabled = true
        var lastSync: Date?
        var syncStatus = ""
        var channels = 0, movies = 0, series = 0
        var guideProgrammes = 0
        var probe: Probe = .skipped
        var warning: String?
        enum Probe: Sendable, Equatable { case skipped, reachable(Int), failed(PlaybackError.Kind) }
    }

    static func sourceHealth(_ s: SourceEvidence, now: Date = Date()) -> AssistantFinding {
        var observed = ["type \(s.kind)", s.enabled ? "switched on" : "switched off", "\(s.channels) channels, \(s.movies) movies, \(s.series) series"]
        if let d = s.lastSync { observed.append("last refreshed \(ago(d, now))") } else { observed.append("never refreshed") }
        if !s.syncStatus.isEmpty, s.syncStatus != "idle" { observed.append("status: \(CredentialRedactor.redact(s.syncStatus))") }
        if let w = s.warning { observed.append(w) }
        switch s.probe {
        case .skipped: break
        case .reachable(let code): observed.append("server answered (\(code))")
        case .failed(let k): observed.append("server check failed (\(k.rawValue))")
        }
        if !s.enabled { return .init(what: "“\(s.name)” is switched off.", why: "A playlist that is off is not refreshed or shown.", cause: .app, observed: observed, next: ["Switch it on in Settings → Library → Manage."], actions: ["open_sources"]) }
        if case .failed(let k) = s.probe {
            switch k {
            case .nameLookup: return .init(what: "“\(s.name)”’s server cannot be found.", why: "The name did not resolve. A DNS filter on this network or a mistyped address are the usual causes.", cause: .network, observed: observed, next: ["Check the server address in the playlist's settings.", "Turn off any DNS filter for this network."], actions: ["open_sources"])
            case .network: return .init(what: "This device cannot reach “\(s.name)” right now.", why: "No connection could be made. This is more likely this network than the provider.", cause: .network, observed: observed, next: ["Check Wi-Fi or mobile data and any VPN or proxy, then run the check again."])
            case .timeout: return .init(what: "“\(s.name)” is slow to answer.", why: "The server did not reply in time. It may be overloaded or down.", cause: .provider, observed: observed, next: ["Run the check again in a few minutes.", "If it stays down, ask the provider."])
            default: return .init(what: "“\(s.name)” could not be checked.", why: "The server check ended with: \(k.rawValue).", cause: .provider, observed: observed, next: ["Run the check again, then check with the provider."])
            }
        }
        if case .reachable(let code) = s.probe, code == 401 || code == 403 {
            return .init(what: "“\(s.name)” answered, but refused.", why: "The server is up but rejected the request. If playback or refreshing fails with it, the login is probably wrong or expired.", cause: .credentials, observed: observed, next: ["Check the username and password with your provider and update them in the playlist's settings."], actions: ["open_sources"])
        }
        if s.syncStatus.lowercased().contains("fail") || s.syncStatus.lowercased().contains("error") {
            return .init(what: "“\(s.name)” could not be refreshed the last time.", why: "The server is reachable, but loading its list failed. \(CredentialRedactor.redact(s.syncStatus)).", cause: .provider, observed: observed, next: ["Refresh it again.", "If it keeps failing, check the playlist address and login."], actions: ["refresh"])
        }
        if s.channels + s.movies + s.series == 0 {
            return .init(what: "“\(s.name)” is connected but has nothing in it yet.", why: "It may not have been refreshed, or the provider's list is empty.", cause: .provider, observed: observed, next: ["Refresh it and wait for it to finish."], actions: ["refresh"])
        }
        return .init(what: "“\(s.name)” looks healthy.", why: "It is reachable and its list is loaded.", cause: .fine, observed: observed)
    }

    static func ago(_ d: Date, _ now: Date) -> String {
        let s = max(0, now.timeIntervalSince(d))
        if s < 90 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) minutes ago" }
        if s < 86400 { return "\(Int(s / 3600)) hours ago" }
        return "\(Int(s / 86400)) days ago"
    }
}
