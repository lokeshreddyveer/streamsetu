import SwiftUI
import Observation

/// User preferences, persisted in UserDefaults under "settings.<key>" (see `SettingsMigrator` for versioning).
/// Nothing secret lives here. Every property has a default, is validated on load, is saved as it changes, and is read by
/// the part of the app it controls; there are no stored-but-unused preferences.
@MainActor @Observable
final class AppSettings {
    private let d: UserDefaults
    private func save(_ v: Any?, _ k: String) { d.set(v, forKey: "settings." + k) }

    // MARK: General
    var theme: AppTheme { didSet { save(theme.rawValue, "theme"); ThemeStore.current = theme } }
    var customTheme: CustomTheme { didSet { save(customTheme.encoded, "customtheme"); ThemeStore.custom = customTheme } }
    /// Changes whenever the colours in force change, so the window can be rebuilt.
    var themeKey: String { theme == .custom ? "custom-" + customTheme.encoded : theme.rawValue }
    var accent: AccentChoice { didSet { save(accent.rawValue, "accent") } }
    var density: LayoutDensity { didSet { save(density.rawValue, "density") } }
    var reduceMotion: Bool { didSet { save(reduceMotion, "reducemotion") } }
    /// Stronger text and outlines for people who find the themes too soft. Also follows the system's Increase Contrast.
    var highContrast: Bool { didSet { save(highContrast, "highcontrast"); ThemeStore.state.userContrast = highContrast } }
    var sidebarLaunch: SidebarLaunch { didSet { save(sidebarLaunch.rawValue, "sidebarlaunch") } }
    /// Last sidebar state, used when `sidebarLaunch` is "Remember last state".
    var sidebarWasCollapsed: Bool { didSet { save(sidebarWasCollapsed, "sidebarcollapsed") } }
    var clickBehavior: ClickBehavior { didSet { save(clickBehavior.rawValue, "click") } }
    var collapseDuplicates: Bool { didSet { save(collapseDuplicates, "collapse") } }
    /// Folders the provider defined but that hold no items right now. Shown by default: ingestion never discards them.
    var hideEmptyFolders: Bool { didSet { save(hideEmptyFolders, "hideemptyfolders") } }
    var defaultLibrarySort: LibrarySortPreference { didSet { save(defaultLibrarySort.rawValue, "libsort") } }
    var defaultChannelSort: ChannelSortPreference { didSet { save(defaultChannelSort.rawValue, "chansort") } }
    var rememberFolders: Bool { didSet { save(rememberFolders, "rememberfolders") } }
    var remindersEnabled: Bool { didSet { save(remindersEnabled, "reminders") } }
    /// Refresh playlists that are more than an hour old each time the app is opened, whatever the schedule says.
    var refreshOnOpen: Bool { didSet { save(refreshOnOpen, "refreshonopen") } }
    /// The language of the app's own wording: the device's, English, Hindi or Telugu.
    var language: AppLanguage { didSet { save(language.rawValue, "language") } }
    /// Start the channel that was playing when REDDY was last closed. Off by default: nothing plays until asked.
    /// Keep a rewindable buffer for live TV so it can be paused and wound back (MPV).
    var liveRewind: Bool { didSet { save(liveRewind, "liverewind") } }
    /// Write a backup by itself once a week.
    var autoBackup: Bool { didSet { save(autoBackup, "autobackup") } }
    /// iCloud sync. These two are choices about this device and are deliberately not synced themselves.
    var iCloudSync: Bool { didSet { save(iCloudSync, "icloudsync") } }
    var syncLogins: Bool { didSet { save(syncLogins, "icloudlogins") } }
    var lanSync: Bool { didSet { save(lanSync, "lansync") } }
    /// Face ID / Touch ID / passcode before the app opens. A choice about this device, so it is not synced.
    var appLock: Bool { didSet { save(appLock, "applock") } }
    /// Pause playback when a connected VPN drops. About this device's network, so it is not synced.
    var vpnPause: Bool { didSet { save(vpnPause, "vpnpause") } }
    /// A proxy for the app's own requests and the MPV player. About this device's network, so it is not synced.
    var proxyKind: ProxyConfig.Kind { didSet { save(proxyKind.rawValue, "proxykind") } }
    var proxyHost: String { didSet { save(proxyHost, "proxyhost") } }
    var proxyPort: Int { didSet { save(proxyPort, "proxyport") } }
    var proxy: ProxyConfig { ProxyConfig(kind: proxyKind, host: proxyHost, port: proxyPort) }
    var lastAutoBackup: Date? { didSet { save(lastAutoBackup, "lastautobackup") } }
    var resumeLastChannel: Bool { didSet { save(resumeLastChannel, "resumelast") } }
    /// The live channel last played (set by playback, not a preference, so it isn't part of backups).
    var lastChannelID: String? { didSet { save(lastChannelID, "lastchannel") } }

    // MARK: Playback
    var enginePreference: PlaybackEnginePreference { didSet { save(enginePreference.rawValue, "engine") } }
    var hardwareDecoding: HardwareDecoding { didSet { save(hardwareDecoding.rawValue, "hwdec2") } }
    var deinterlace: DeinterlaceMode { didSet { save(deinterlace.rawValue, "deinterlace2") } }
    var videoQuality: VideoQualityPreference { didSet { save(videoQuality.rawValue, "quality") } }
    var bufferingMode: BufferingMode { didSet { save(bufferingMode.rawValue, "buffering") } }
    var volume: Double { didSet { save(volume, "volume") } }
    var preferredAudioLanguage: String { didSet { save(preferredAudioLanguage, "alang") } }
    var audioOutputUID: String { didSet { save(audioOutputUID, "audiodev") } }
    var audioProcessing: AudioProcessingMode { didSet { save(audioProcessing.rawValue, "audioproc") } }
    var preferredSubtitleLanguage: String { didSet { save(preferredSubtitleLanguage, "slang") } }
    var subtitlesByDefault: Bool { didSet { save(subtitlesByDefault, "subsdefault") } }
    /// Fetches a subtitle from OpenSubtitles by itself when a film or episode has none in the chosen language. Needs the free account set up under Playback.
    var autoSubtitles: Bool { didSet { save(autoSubtitles, "autosubs") } }
    var subtitleSize: Double { didSet { save(subtitleSize, "subsize") } }
    var subtitleBackground: Double { didSet { save(subtitleBackground, "subbg") } }
    var subtitleColor: SubtitleColor { didSet { save(subtitleColor.rawValue, "subcolor") } }
    var subtitlePosition: Double { didSet { save(subtitlePosition, "subpos") } }
    var autoPlayNextEpisode: Bool { didSet { save(autoPlayNextEpisode, "autonext") } }
    /// When off, no resume points are written, so nothing can be resumed later.
    var rememberPosition: Bool { didSet { save(rememberPosition, "rememberpos") } }
    /// When on, a partly watched movie or episode continues where it stopped; when off it starts from the beginning.
    var resumeAutomatically: Bool { didSet { save(resumeAutomatically, "autoresume") } }
    /// A film that is in the library in several qualities or folders starts with the best copy; if it does not play, the next best is tried.
    var bestVersionFirst: Bool { didSet { save(bestVersionFirst, "bestversion") } }
    var showDiagnosticsOverlay: Bool { didSet { save(showDiagnosticsOverlay, "diagoverlay") } }
    var renderingProfile: RenderingProfile { didSet { save(renderingProfile.rawValue, "rendering") } }
    /// Mixes surround audio down to two channels (MPV only; AVPlayer chooses by output device).
    var toneMapping: HDRToneMapping { didSet { save(toneMapping.rawValue, "tonemapping") } }
    /// Colour adjustments applied to every stream MPV plays (stored as JSON).
    var picture: PictureAdjustments { didSet { if let d = try? JSONEncoder().encode(picture) { save(d, "picture") } } }
    var stereoDownmix: Bool { didSet { save(stereoDownmix, "downmix") } }
    var subtitleOutline: Bool { didSet { save(subtitleOutline, "suboutline") } }

    // MARK: one player engine for each kind of viewing

    /// What a stream is, for choosing its player: live TV, a movie or episode, or a past programme from the provider's archive.
    enum ViewingKind: String, CaseIterable, Identifiable {
        case live, movies, catchup
        var id: String { rawValue }
        var title: String { switch self { case .live: "Live TV"; case .movies: "Movies and series"; case .catchup: "Past programmes" } }
    }

    /// The engine chosen for one kind of viewing; nil means "use the app-wide setting". A playlist's or channel's own choice still wins over it.
    func engineChoice(for kind: ViewingKind) -> PlaybackEnginePreference? {
        d.string(forKey: "engine.kind.\(kind.rawValue)").flatMap(PlaybackEnginePreference.init(rawValue:))
    }
    func setEngineChoice(_ v: PlaybackEnginePreference?, for kind: ViewingKind) {
        let key = "engine.kind.\(kind.rawValue)"
        if let v { d.set(v.rawValue, forKey: key) } else { d.removeObject(forKey: key) }
    }

    // MARK: per-playlist playback overrides

    /// Engine and buffering chosen for one playlist. Nil means "use the app-wide setting". IPTV providers differ, so a playlist
    /// can need its own choice without changing every other one.
    func engineOverride(for source: UUID) -> PlaybackEnginePreference? {
        d.string(forKey: "playlist.\(source.uuidString.lowercased()).engine").flatMap(PlaybackEnginePreference.init(rawValue:))
    }
    func setEngineOverride(_ v: PlaybackEnginePreference?, for source: UUID) {
        let key = "playlist.\(source.uuidString.lowercased()).engine"
        if let v { d.set(v.rawValue, forKey: key) } else { d.removeObject(forKey: key) }
    }
    /// Minutes to move one playlist's programme guide by. IPTV guides are often several hours off; this corrects it for that playlist
    /// only. It is applied when the guide is imported, so changing it needs a guide refresh.
    func guideShiftMinutes(for source: UUID) -> Int {
        d.object(forKey: Self.guideShiftKey(source)) as? Int ?? 0
    }
    func setGuideShiftMinutes(_ minutes: Int, for source: UUID) {
        d.set(max(-1440, min(1440, minutes)), forKey: Self.guideShiftKey(source))
    }
    nonisolated static func guideShiftKey(_ source: UUID) -> String { "playlist.\(source.uuidString.lowercased()).guideshift" }
    var defaultsStore: UserDefaults { d }

    /// Re-reads everything from storage, after another device changed the synced settings.
    func reloadFromStore() { copy(from: AppSettings(defaults: d)) }

    /// The provider's clock for catch-up addresses, in minutes from UTC. Providers differ, so it is chosen per playlist.
    func catchupOffsetMinutes(for source: UUID) -> Int {
        let key = "playlist.\(source.uuidString.lowercased()).catchupoffset"
        return d.object(forKey: key) as? Int ?? 0
    }
    func setCatchupOffsetMinutes(_ minutes: Int, for source: UUID) {
        d.set(max(-720, min(840, minutes)), forKey: "playlist.\(source.uuidString.lowercased()).catchupoffset")
    }
    func bufferingOverride(for source: UUID) -> BufferingMode? {
        d.string(forKey: "playlist.\(source.uuidString.lowercased()).buffering").flatMap(BufferingMode.init(rawValue:))
    }
    func setBufferingOverride(_ v: BufferingMode?, for source: UUID) {
        let key = "playlist.\(source.uuidString.lowercased()).buffering"
        if let v { d.set(v.rawValue, forKey: key) } else { d.removeObject(forKey: key) }
    }

    // MARK: Library
    var catalogRefresh: RefreshInterval { didSet { save(catalogRefresh.rawValue, "catalogrefresh") } }
    var guideRefresh: RefreshInterval { didSet { save(guideRefresh.rawValue, "guiderefresh") } }
    /// Days of past programmes kept in the guide (future programmes are always kept).
    var guideRetentionDays: Int { didSet { save(guideRetentionDays, "guideretention") } }
    var guideHoursVisible: Double { didSet { save(guideHoursVisible, "guidehours") } }

    // MARK: defaults & validation

    enum Defaults {
        static let theme = AppTheme.cinematic, accent = AccentChoice.coral, density = LayoutDensity.comfortable, reduceMotion = false
        static let sidebarLaunch = SidebarLaunch.expanded, click = ClickBehavior.doubleClick
        static let engine = PlaybackEnginePreference.automatic, hardware = HardwareDecoding.automatic, deinterlace = DeinterlaceMode.automatic
        static let quality = VideoQualityPreference.automatic, buffering = BufferingMode.automatic, volume = 1.0
        static let audioProcessing = AudioProcessingMode.off
        static let subtitleSize = 100.0, subtitleBackground = 0.5, subtitleColor = SubtitleColor.white, subtitlePosition = 0.0
        static let catalogRefresh = RefreshInterval.every12, guideRefresh = RefreshInterval.every6, guideRetentionDays = 1, guideHours = 3.0
    }

    static func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double { min(r.upperBound, max(r.lowerBound, v.isFinite ? v : r.lowerBound)) }

    init(defaults: UserDefaults = .standard) {
        d = defaults
        SettingsMigrator.migrate(defaults)
        func get<T: RawRepresentable>(_ k: String, _ def: T) -> T where T.RawValue == String {
            if let s = defaults.string(forKey: "settings." + k), let v = T(rawValue: s) { return v }
            return def
        }
        func bool(_ k: String, _ def: Bool) -> Bool { defaults.object(forKey: "settings." + k) as? Bool ?? def }
        func dbl(_ k: String, _ def: Double) -> Double { defaults.object(forKey: "settings." + k) as? Double ?? def }
        func str(_ k: String, _ def: String) -> String { defaults.string(forKey: "settings." + k) ?? def }

        let storedCustom = CustomTheme(encoded: str("customtheme", "")) ?? .standard
        customTheme = storedCustom
        ThemeStore.custom = storedCustom
        iCloudSync = bool("icloudsync", false)
        syncLogins = bool("icloudlogins", true)
        lanSync = bool("lansync", false)
        appLock = bool("applock", false)
        vpnPause = bool("vpnpause", false)
        proxyKind = ProxyConfig.Kind(rawValue: str("proxykind", "Off")) ?? .off
        proxyHost = str("proxyhost", "")
        proxyPort = Int(dbl("proxyport", 0))
        // The redesign: everyone starts on the new Cinematic look once; after that their own choice is kept.
        if !bool("design2", false) { defaults.set("Cinematic", forKey: "settings.theme"); defaults.set(true, forKey: "settings.design2") }
        theme = get("theme", Defaults.theme)
        accent = get("accent", Defaults.accent)
        density = get("density", Defaults.density)
        reduceMotion = bool("reducemotion", Defaults.reduceMotion)
        let hc = bool("highcontrast", false)
        highContrast = hc
        ThemeStore.state.userContrast = hc
        sidebarLaunch = get("sidebarlaunch", Defaults.sidebarLaunch)
        sidebarWasCollapsed = bool("sidebarcollapsed", false)
        clickBehavior = get("click", Defaults.click)
        collapseDuplicates = bool("collapse", true)
        hideEmptyFolders = bool("hideemptyfolders", false)
        defaultLibrarySort = get("libsort", .recentlyAdded)
        defaultChannelSort = get("chansort", .provider)
        rememberFolders = bool("rememberfolders", true)
        remindersEnabled = bool("reminders", true)
        refreshOnOpen = bool("refreshonopen", true)
        language = get("language", AppLanguage.system)
        resumeLastChannel = bool("resumelast", false)
        autoBackup = bool("autobackup", true)
        lastAutoBackup = defaults.object(forKey: "settings.lastautobackup") as? Date
        liveRewind = bool("liverewind", true)
        lastChannelID = defaults.string(forKey: "settings.lastchannel")

        enginePreference = get("engine", Defaults.engine)
        hardwareDecoding = get("hwdec2", Defaults.hardware)
        deinterlace = get("deinterlace2", Defaults.deinterlace)
        videoQuality = get("quality", Defaults.quality)
        bufferingMode = get("buffering", Defaults.buffering)
        volume = Self.clamp(dbl("volume", Defaults.volume), 0...1)
        preferredAudioLanguage = str("alang", "")
        audioOutputUID = str("audiodev", "")
        audioProcessing = get("audioproc", Defaults.audioProcessing)
        preferredSubtitleLanguage = str("slang", "")
        subtitlesByDefault = bool("subsdefault", false)
        autoSubtitles = bool("autosubs", false)
        subtitleSize = Self.clamp(dbl("subsize", Defaults.subtitleSize), 60...200)
        subtitleBackground = Self.clamp(dbl("subbg", Defaults.subtitleBackground), 0...1)
        subtitleColor = get("subcolor", Defaults.subtitleColor)
        subtitlePosition = Self.clamp(dbl("subpos", Defaults.subtitlePosition), 0...1)
        autoPlayNextEpisode = bool("autonext", true)
        rememberPosition = bool("rememberpos", true)
        resumeAutomatically = bool("autoresume", true)
        bestVersionFirst = bool("bestversion", true)
        showDiagnosticsOverlay = bool("diagoverlay", false)
        renderingProfile = get("rendering", .balanced)
        stereoDownmix = bool("downmix", false)
        toneMapping = get("tonemapping", .automatic)
        picture = (defaults.data(forKey: "settings.picture")).flatMap { try? JSONDecoder().decode(PictureAdjustments.self, from: $0) }?.clamped() ?? PictureAdjustments()
        subtitleOutline = bool("suboutline", true)

        catalogRefresh = get("catalogrefresh", Defaults.catalogRefresh)
        guideRefresh = get("guiderefresh", Defaults.guideRefresh)
        guideRetentionDays = min(14, max(0, (defaults.object(forKey: "settings.guideretention") as? Int) ?? Defaults.guideRetentionDays))
        guideHoursVisible = [2.0, 3.0, 4.0, 6.0].contains(dbl("guidehours", Defaults.guideHours)) ? dbl("guidehours", Defaults.guideHours) : Defaults.guideHours
        ThemeStore.current = theme
    }

    // MARK: derived

    var audioLanguages: [String] { preferredAudioLanguage.isEmpty ? [] : [preferredAudioLanguage] }
    var subtitleLanguages: [String] { preferredSubtitleLanguage.isEmpty ? [] : [preferredSubtitleLanguage] }
    var subtitleStyle: SubtitleStyle { SubtitleStyle(sizePercent: subtitleSize, backgroundOpacity: subtitleBackground, color: subtitleColor, verticalPosition: subtitlePosition, outline: subtitleOutline) }

    // MARK: reset

    func resetAppearance() {
        theme = Defaults.theme; customTheme = .standard; accent = Defaults.accent; density = Defaults.density; reduceMotion = Defaults.reduceMotion
        sidebarLaunch = Defaults.sidebarLaunch; sidebarWasCollapsed = false
    }

    func resetPlayback() {
        enginePreference = Defaults.engine; hardwareDecoding = Defaults.hardware; deinterlace = Defaults.deinterlace
        videoQuality = Defaults.quality; bufferingMode = Defaults.buffering; audioProcessing = Defaults.audioProcessing
        preferredAudioLanguage = ""; audioOutputUID = ""; preferredSubtitleLanguage = ""; subtitlesByDefault = false; autoSubtitles = false
        subtitleSize = Defaults.subtitleSize; subtitleBackground = Defaults.subtitleBackground; subtitleColor = Defaults.subtitleColor; subtitlePosition = Defaults.subtitlePosition
        autoPlayNextEpisode = true; rememberPosition = true; resumeAutomatically = true; bestVersionFirst = true; showDiagnosticsOverlay = false
        liveRewind = true; autoBackup = true; renderingProfile = .balanced; stereoDownmix = false; subtitleOutline = true; toneMapping = .automatic; picture = PictureAdjustments()
    }

    /// Everything except the sources, favorites and history, which are data rather than preferences.
    func resetAll() {
        resetAppearance(); resetPlayback()
        clickBehavior = Defaults.click; collapseDuplicates = true; hideEmptyFolders = false
        defaultLibrarySort = .recentlyAdded; defaultChannelSort = .provider; rememberFolders = true; remindersEnabled = true; refreshOnOpen = true; language = .system; resumeLastChannel = false
        catalogRefresh = Defaults.catalogRefresh; guideRefresh = Defaults.guideRefresh; guideRetentionDays = Defaults.guideRetentionDays
        guideHoursVisible = Defaults.guideHours; volume = Defaults.volume
    }

    // MARK: backup

    /// Every preference as plain values, for backups. Contains no secrets.
    func snapshot() -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in d.dictionaryRepresentation() where k.hasPrefix("settings.") && k != SettingsMigrator.versionKey {
            if let s = v as? String { out[k] = s } else if let b = v as? Bool { out[k] = b ? "true" : "false" } else if let n = v as? NSNumber { out[k] = n.stringValue }
        }
        return out
    }

    /// Applies a snapshot, accepting only known keys and values that validate. Returns how many were applied.
    @discardableResult
    func apply(snapshot: [String: String]) -> Int {
        var applied = 0
        for (key, value) in snapshot where key.hasPrefix("settings.") && Self.knownKeys.contains(key) {
            if let typed = Self.typedValue(key, value) { d.set(typed, forKey: key); applied += 1 }
        }
        let fresh = AppSettings(defaults: d)
        copy(from: fresh)
        return applied
    }

    private func copy(from o: AppSettings) {
        theme = o.theme; customTheme = o.customTheme; accent = o.accent; density = o.density; reduceMotion = o.reduceMotion; sidebarLaunch = o.sidebarLaunch; clickBehavior = o.clickBehavior
        collapseDuplicates = o.collapseDuplicates; hideEmptyFolders = o.hideEmptyFolders; defaultLibrarySort = o.defaultLibrarySort
        defaultChannelSort = o.defaultChannelSort; rememberFolders = o.rememberFolders; remindersEnabled = o.remindersEnabled; refreshOnOpen = o.refreshOnOpen; language = o.language; resumeLastChannel = o.resumeLastChannel
        enginePreference = o.enginePreference; hardwareDecoding = o.hardwareDecoding; deinterlace = o.deinterlace; videoQuality = o.videoQuality
        bufferingMode = o.bufferingMode; audioProcessing = o.audioProcessing; preferredAudioLanguage = o.preferredAudioLanguage
        preferredSubtitleLanguage = o.preferredSubtitleLanguage; subtitlesByDefault = o.subtitlesByDefault; subtitleSize = o.subtitleSize
        subtitleBackground = o.subtitleBackground; subtitleColor = o.subtitleColor; subtitlePosition = o.subtitlePosition
        autoPlayNextEpisode = o.autoPlayNextEpisode; rememberPosition = o.rememberPosition; resumeAutomatically = o.resumeAutomatically
        showDiagnosticsOverlay = o.showDiagnosticsOverlay; liveRewind = o.liveRewind; autoBackup = o.autoBackup; renderingProfile = o.renderingProfile; toneMapping = o.toneMapping; picture = o.picture; stereoDownmix = o.stereoDownmix; subtitleOutline = o.subtitleOutline; catalogRefresh = o.catalogRefresh; guideRefresh = o.guideRefresh
        guideRetentionDays = o.guideRetentionDays; guideHoursVisible = o.guideHoursVisible
    }

    /// Preferences that make sense to carry to another Mac. Output devices are machine-specific and are left out.
    nonisolated static let knownKeys: Set<String> = [
        "theme", "customtheme", "accent", "density", "reducemotion", "highcontrast", "sidebarlaunch", "click", "collapse", "hideemptyfolders", "libsort", "chansort", "rememberfolders", "reminders", "refreshonopen", "language", "resumelast",
        "engine", "hwdec2", "deinterlace2", "quality", "buffering", "alang", "audioproc", "slang", "subsdefault", "subsize", "subbg", "subcolor", "subpos",
        "autonext", "rememberpos", "autoresume", "diagoverlay", "rendering", "downmix", "suboutline", "tonemapping", "liverewind", "autobackup", "catalogrefresh", "guiderefresh", "guideretention", "guidehours",
    ].reduce(into: Set<String>()) { $0.insert("settings." + $1) }

    private static func typedValue(_ key: String, _ s: String) -> Any? {
        let bools: Set<String> = ["reducemotion", "collapse", "hideemptyfolders", "rememberfolders", "reminders", "refreshonopen", "resumelast", "subsdefault", "autonext", "rememberpos", "autoresume", "diagoverlay", "downmix", "suboutline", "liverewind", "autobackup"].reduce(into: Set<String>()) { $0.insert("settings." + $1) }
        if bools.contains(key) { return s == "true" || s == "1" ? true : (s == "false" || s == "0" ? false : nil) }
        switch key.dropFirst("settings.".count) {
        case "subsize": return Double(s).map { clamp($0, 60...200) }
        case "subbg", "subpos": return Double(s).map { clamp($0, 0...1) }
        case "guidehours": return Double(s).flatMap { [2.0, 3.0, 4.0, 6.0].contains($0) ? $0 : nil }
        case "guideretention": return Int(s).map { min(14, max(0, $0)) }
        case "language": return AppLanguage(rawValue: s)?.rawValue
        case "theme": return AppTheme(rawValue: s)?.rawValue
        case "customtheme": return CustomTheme(encoded: s)?.encoded
        case "accent": return AccentChoice(rawValue: s)?.rawValue
        case "density": return LayoutDensity(rawValue: s)?.rawValue
        case "sidebarlaunch": return SidebarLaunch(rawValue: s)?.rawValue
        case "click": return ClickBehavior(rawValue: s)?.rawValue
        case "libsort": return LibrarySortPreference(rawValue: s)?.rawValue
        case "chansort": return ChannelSortPreference(rawValue: s)?.rawValue
        case "engine": return PlaybackEnginePreference(rawValue: s)?.rawValue
        case "hwdec2": return HardwareDecoding(rawValue: s)?.rawValue
        case "deinterlace2": return DeinterlaceMode(rawValue: s)?.rawValue
        case "quality": return VideoQualityPreference(rawValue: s)?.rawValue
        case "buffering": return BufferingMode(rawValue: s)?.rawValue
        case "audioproc": return AudioProcessingMode(rawValue: s)?.rawValue
        case "subcolor": return SubtitleColor(rawValue: s)?.rawValue
        case "rendering": return RenderingProfile(rawValue: s)?.rawValue
        case "tonemapping": return HDRToneMapping(rawValue: s)?.rawValue
        case "catalogrefresh", "guiderefresh": return RefreshInterval(rawValue: s)?.rawValue
        case "alang", "slang": return s.count <= 8 && s.allSatisfy { $0.isLetter || $0 == "-" } ? s : nil
        default: return nil
        }
    }
}
