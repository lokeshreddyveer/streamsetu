import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - General

enum ClickBehavior: String, CaseIterable, Identifiable {
    case singleClick = "Single click plays", doubleClick = "Double click plays"
    var id: String { rawValue }
    var title: String { self == .singleClick ? "Single click" : "Double click" }
}

enum AccentChoice: String, CaseIterable, Identifiable {
    // The first five keep their stored names, so saved preferences still load.
    case coral = "Coral", blue = "Blue", purple = "Purple", green = "Green", system = "System"
    case red = "Red", orange = "Orange", amber = "Amber", yellow = "Yellow", lime = "Lime", mint = "Mint", teal = "Teal", cyan = "Cyan"
    case sky = "Sky", indigo = "Indigo", violet = "Violet", magenta = "Magenta", pink = "Pink", rose = "Rose", gold = "Gold", silver = "Silver"
    var id: String { rawValue }
    var title: String { self == .coral ? "Theme colour" : self == .system ? "System accent" : rawValue }
    var color: Color {
        switch self {
        case .coral: ColorTokens.accentDefault
        case .blue: Color(red: 0.25, green: 0.52, blue: 0.96)
        case .purple: Color(red: 0.55, green: 0.40, blue: 0.95)
        case .green: Color(red: 0.20, green: 0.74, blue: 0.45)
        #if os(macOS)
        case .system: Color(nsColor: .controlAccentColor)
        #else
        case .system: Color.accentColor
        #endif
        case .red: Color(hex: 0xEF4444)
        case .orange: Color(hex: 0xF97316)
        case .amber: Color(hex: 0xF59E0B)
        case .yellow: Color(hex: 0xEAB308)
        case .lime: Color(hex: 0x84CC16)
        case .mint: Color(hex: 0x34D399)
        case .teal: Color(hex: 0x14B8A6)
        case .cyan: Color(hex: 0x06B6D4)
        case .sky: Color(hex: 0x38BDF8)
        case .indigo: Color(hex: 0x6366F1)
        case .violet: Color(hex: 0x8B5CF6)
        case .magenta: Color(hex: 0xD946EF)
        case .pink: Color(hex: 0xEC4899)
        case .rose: Color(hex: 0xF43F5E)
        case .gold: Color(hex: 0xD4AF37)
        case .silver: Color(hex: 0xA8B0BD)
        }
    }
}

enum LayoutDensity: String, CaseIterable, Identifiable {
    case comfortable = "Comfortable", compact = "Compact", extraCompact = "Extra Compact"
    var id: String { rawValue }
    var posterRange: (min: CGFloat, max: CGFloat) {
        switch self { case .comfortable: (140, 190); case .compact: (120, 160); case .extraCompact: (104, 138) }
    }
    var channelRowHeight: CGFloat { switch self { case .comfortable: 46; case .compact: 40; case .extraCompact: 34 } }
    var sidebarRowHeight: CGFloat { switch self { case .comfortable: 30; case .compact: 27; case .extraCompact: 24 } }
}

enum SidebarLaunch: String, CaseIterable, Identifiable {
    case expanded = "Expanded", collapsed = "Collapsed", remember = "Remember last state"
    var id: String { rawValue }
}

enum LibrarySortPreference: String, CaseIterable, Identifiable {
    case recentlyAdded = "Recently added", titleAZ = "Title: A–Z", newest = "Newest first", topRated = "Top rated"
    var id: String { rawValue }
    var sort: LibrarySort {
        switch self { case .recentlyAdded: .recentlyAdded; case .titleAZ: .titleAZ; case .newest: .newestYear; case .topRated: .topRated }
    }
}

enum ChannelSortPreference: String, CaseIterable, Identifiable {
    case provider = "Provider order", alphabetical = "Alphabetical", recentlyAdded = "Recently added"
    var id: String { rawValue }
}

// MARK: - Playback

enum HardwareDecoding: String, CaseIterable, Identifiable {
    case automatic = "Automatic", enabled = "Enabled where supported", software = "Software decoding"
    var id: String { rawValue }
    /// libmpv's `hwdec` value.
    var mpvValue: String { switch self { case .automatic: "auto-safe"; case .enabled: "videotoolbox-copy"; case .software: "no" } }
    var explanation: String {
        switch self {
        case .automatic: "MPV uses a hardware decoder only when it is known to work for the stream."
        case .enabled: "Always asks for VideoToolbox. Falls back to software when the codec isn't supported."
        case .software: "Decodes on the CPU. Uses more power; useful if a stream shows artifacts."
        }
    }
}

enum DeinterlaceMode: String, CaseIterable, Identifiable {
    case automatic = "Automatic", on = "On", off = "Off"
    var id: String { rawValue }
    func isOn(live: Bool) -> Bool { self == .on || (self == .automatic && live) }
}

enum VideoQualityPreference: String, CaseIterable, Identifiable {
    case automatic = "Automatic", highest = "Highest available", balanced = "Balanced", dataSaver = "Data saver"
    var id: String { rawValue }
    /// AVPlayer's `preferredPeakBitRate` in bits per second (0 = no limit).
    var peakBitRate: Double { switch self { case .automatic, .highest: 0; case .balanced: 4_000_000; case .dataSaver: 1_500_000 } }
    /// libmpv's `hls-bitrate`.
    var mpvHLSBitrate: String { switch self { case .automatic, .balanced: "no"; case .highest: "max"; case .dataSaver: "min" } }
    var explanation: String {
        switch self {
        case .automatic: "The player chooses a variant for your connection."
        case .highest: "Starts with the highest-quality variant the stream offers."
        case .balanced: "Caps the bitrate at about 4 Mbit/s."
        case .dataSaver: "Caps the bitrate at about 1.5 Mbit/s, or picks the lowest variant."
        }
    }
}

extension BufferingMode {
    /// Seconds of media MPV keeps ahead. Low latency uses mpv's low-latency profile instead of a bigger cache.
    var mpvCacheSeconds: Int { switch self { case .automatic: 10; case .lowLatency: 2; case .standard: 20; case .large: 60 } }

    /// Seconds of media MPV wants buffered before it resumes after running dry. Too small and a weak connection stalls again a
    /// moment after every restart, which looks like constant buffering; a few seconds trades one longer wait for steady playback.
    func mpvResumeThreshold(live: Bool) -> Double {
        switch self { case .automatic: live ? 3 : 1.5; case .lowLatency: 0.5; case .standard: 4; case .large: 8 }
    }

    var title: String { switch self { case .automatic: "Automatic"; case .lowLatency: "Low latency"; case .standard: "Balanced"; case .large: "Stability" } }
    var explanation: String {
        switch self {
        case .automatic: "The engine decides. Recommended."
        case .lowLatency: "Less delay on live TV, with a higher chance of buffering on weak connections."
        case .standard: "A moderate buffer. A good default for most connections."
        case .large: "A larger buffer for unreliable connections. Live streams run further behind."
        }
    }
}

extension AudioProcessingMode {
    var title: String { rawValue }
    var explanation: String {
        switch self { case .off: "No processing."; case .standard: "Evens out loudness differences between programmes."; case .nightMode: "Compresses loud peaks so dialogue stays clear at low volume." }
    }
}

// MARK: - Library

enum RefreshInterval: String, CaseIterable, Identifiable {
    case manual = "Manual", every6 = "Every 6 hours", every12 = "Every 12 hours", every24 = "Every 24 hours"
    var id: String { rawValue }
    var seconds: TimeInterval? { switch self { case .manual: nil; case .every6: 6 * 3600; case .every12: 12 * 3600; case .every24: 24 * 3600 } }
}


/// How MPV scales and converts video. Only MPV exposes these, so the control is disabled when MPV isn't available.
enum RenderingProfile: String, CaseIterable, Identifiable {
    case performance = "Performance", balanced = "Balanced", highQuality = "High quality"
    var id: String { rawValue }
    var explanation: String {
        switch self {
        case .performance: "Cheapest scaling. Best for older Macs, many windows or 4K streams."
        case .balanced: "Good scaling at a small cost. Recommended."
        case .highQuality: "Sharpest scaling and downscaling. Uses the most GPU."
        }
    }
    /// libmpv options for the scalers.
    var mpvOptions: [(String, String)] {
        switch self {
        case .performance: [("scale", "bilinear"), ("cscale", "bilinear"), ("dscale", "bilinear"), ("correct-downscaling", "no")]
        case .balanced: [("scale", "spline36"), ("cscale", "bilinear"), ("dscale", "mitchell"), ("correct-downscaling", "yes")]
        case .highQuality: [("scale", "ewa_lanczossharp"), ("cscale", "ewa_lanczossharp"), ("dscale", "mitchell"), ("correct-downscaling", "yes")]
        }
    }
}
