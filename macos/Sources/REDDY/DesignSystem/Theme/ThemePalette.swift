import Observation
#if os(macOS)
import AppKit
#endif
import SwiftUI

/// A complete set of interface colours. Every colour in the app comes from the current palette through `ColorTokens`.
struct ThemePalette: Sendable {
    var background: UInt32       // window and page
    var panel: UInt32            // sidebar
    var surface: UInt32          // panels inside a page
    var card: UInt32
    var elevated: UInt32         // controls, raised rows
    var accent: UInt32
    var text: UInt32
    var textSecondary: UInt32
    var textTertiary: UInt32
    var bar: UInt32              // top bar and bottom player, drawn over a blur
    var glass: UInt32            // menus and dialogs
    /// 0…1: how strong the top-lit sheen on the sidebar, bars, panels and cards is. A flat theme uses a little; a glossy one a lot.
    var sheen: Double
    /// Opacity of the bright hairline along the top edge of glossy surfaces.
    var highlight: Double
    /// Translucent theme: sidebar, bars, panels and cards are frosted glass over a lit backdrop instead of opaque fills.
    var glassy = false
    /// Use Apple's own Liquid Glass material (macOS 26 and later) instead of the app's frosted approximation.
    var nativeGlass = false
    /// Backdrop corners (top-leading → bottom-trailing) and two soft glows, used only by glassy themes.
    var backdrop: [UInt32] = []
    var glows: [UInt32] = []

    static func make(_ background: UInt32, _ panel: UInt32, _ surface: UInt32, _ card: UInt32, _ elevated: UInt32, _ accent: UInt32,
                     _ text: UInt32, _ secondary: UInt32, _ tertiary: UInt32, _ bar: UInt32, _ glass: UInt32, _ sheen: Double, _ highlight: Double) -> ThemePalette {
        ThemePalette(background: background, panel: panel, surface: surface, card: card, elevated: elevated, accent: accent, text: text,
                     textSecondary: secondary, textTertiary: tertiary, bar: bar, glass: glass, sheen: sheen, highlight: highlight)
    }
}

/// The themes a person can choose. Palettes follow the well-known editor themes of the same names, adapted for this interface.
enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case cinematic = "Cinematic", obsidian = "Obsidian", onyx = "Onyx Gloss", piano = "Piano Black", glossyBlack = "Glossy Black", liquidGlass = "Liquid Glass", midnight = "Midnight", dracula = "Dracula", nord = "Nord"
    case mocha = "Mocha", rosePine = "Rosé Pine", gruvbox = "Gruvbox"
    case solarized = "Solarized Dark", oneDark = "One Dark", monokai = "Monokai", ayu = "Ayu Mirage", everforest = "Everforest"
    case kanagawa = "Kanagawa", materialOcean = "Material Ocean", synthwave = "Synthwave", neon = "Neon"
    case forest = "Forest Night", crimson = "Crimson", amber = "Amber Night", graphite = "Graphite", deepOcean = "Deep Ocean", amethyst = "Amethyst"
    case custom = "Custom"
    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .cinematic: "Ink black with a warm ember accent, soft glass and large rounded artwork. The default."
        case .obsidian: "Smoked black."
        case .onyx: "Deep black with a glossy sheen."
        case .piano: "True black, high gloss, cool blue accent."
        case .glossyBlack: "Complete piano-black glass: frosted panels, mirror-bright edges, lit backdrop."
        case .liquidGlass: "Apple's real Liquid Glass material on macOS 26 and later, over a deep blue backdrop."
        case .midnight: "Blue-violet night, after Tokyo Night."
        case .dracula: "Dark purple, after Dracula."
        case .nord: "Cool arctic blue-grey, after Nord."
        case .mocha: "Soft lavender, after Catppuccin Mocha."
        case .rosePine: "Muted rose and iris, after Rosé Pine."
        case .gruvbox: "Warm retro brown and orange, after Gruvbox."
        case .solarized: "Teal-tinted dark, after Solarized."
        case .oneDark: "Balanced blue-grey, after Atom One Dark."
        case .monokai: "Olive dark with a lime accent, after Monokai."
        case .ayu: "Slate blue with a golden accent, after Ayu Mirage."
        case .everforest: "Soft forest green and warm grey, after Everforest."
        case .kanagawa: "Ink-blue Japanese woodblock tones, after Kanagawa."
        case .materialOcean: "Deep ocean blue, after Material Ocean."
        case .synthwave: "Retro purple with a hot pink accent, after Synthwave ’84."
        case .neon: "Near-black with a cyan neon glow."
        case .forest: "Black-green with a mint accent."
        case .crimson: "Black with a deep red accent and a soft gloss."
        case .amber: "Warm brown-black with an amber accent."
        case .graphite: "Neutral Apple-style grey with a blue accent."
        case .deepOcean: "Dark teal with an aqua accent."
        case .amethyst: "Purple-black with a violet accent."
        case .custom: "Your own colours. Edit them below."
        }
    }

    /// How the theme picker groups the list.
    enum Group: String, CaseIterable { case black = "Black and glossy", classic = "Editor classics", colour = "Colour", yours = "Yours" }
    var group: Group {
        switch self {
        case .cinematic, .obsidian, .onyx, .piano, .glossyBlack, .liquidGlass, .graphite, .neon, .crimson: .black
        case .midnight, .dracula, .nord, .mocha, .rosePine, .gruvbox, .solarized, .oneDark, .monokai, .ayu, .everforest, .kanagawa, .materialOcean, .synthwave: .classic
        case .forest, .amber, .deepOcean, .amethyst: .colour
        case .custom: .yours
        }
    }

    var palette: ThemePalette {
        switch self {
        case .cinematic:
            ThemePalette(background: 0x07080C, panel: 0x0D0F15, surface: 0x0B0D13, card: 0x13161F, elevated: 0x1B1F2B, accent: 0xFF6B3D,
                         text: 0xF7F4EF, textSecondary: 0xA9A8B6, textTertiary: 0x76778A, bar: 0x06070A, glass: 0x0A0C12, sheen: 0.05, highlight: 0.07)
        case .obsidian:
            ThemePalette(background: 0x0B0D12, panel: 0x11141B, surface: 0x0F1218, card: 0x151922, elevated: 0x1B202A, accent: 0x2BB8F0,
                         text: 0xF5F6F8, textSecondary: 0xA2A7B2, textTertiary: 0x77808E, bar: 0x07090C, glass: 0x080A0E, sheen: 0.035, highlight: 0.0)
        case .onyx:
            ThemePalette(background: 0x040405, panel: 0x09090B, surface: 0x070709, card: 0x101013, elevated: 0x18181D, accent: 0xFF4D5A,
                         text: 0xF7F7F8, textSecondary: 0xA6A6AF, textTertiary: 0x76767F, bar: 0x000000, glass: 0x020203, sheen: 0.16, highlight: 0.26)
        case .piano:
            ThemePalette(background: 0x000000, panel: 0x050507, surface: 0x030305, card: 0x0C0C10, elevated: 0x15151B, accent: 0x4DA3FF,
                         text: 0xFAFAFC, textSecondary: 0xA9ABB5, textTertiary: 0x70727D, bar: 0x000000, glass: 0x000000, sheen: 0.24, highlight: 0.38)
        case .glossyBlack:
            ThemePalette(background: 0x000000, panel: 0x08080B, surface: 0x0B0B0F, card: 0x14141A, elevated: 0x1E1E26, accent: 0x6AB0FF,
                         text: 0xFAFAFC, textSecondary: 0xB0B2BC, textTertiary: 0x777A86, bar: 0x000000, glass: 0x000000, sheen: 0.30, highlight: 0.50,
                         glassy: true, backdrop: [0x14141C, 0x050507, 0x000000], glows: [0x2A3A66, 0x3A2A55])
        case .liquidGlass:
            ThemePalette(background: 0x0A1020, panel: 0x101A33, surface: 0x14203E, card: 0x1B2A4D, elevated: 0x25365F, accent: 0x5EA8FF,
                         text: 0xF4F7FF, textSecondary: 0xB4C0DC, textTertiary: 0x7C8BAE, bar: 0x0B1226, glass: 0x0A1226, sheen: 0.26, highlight: 0.46,
                         glassy: true, nativeGlass: true, backdrop: [0x18305E, 0x0B1226, 0x1A0F33], glows: [0x3A78FF, 0xB05CFF])
        case .midnight:
            ThemePalette(background: 0x1A1B26, panel: 0x16161E, surface: 0x1F2335, card: 0x24283B, elevated: 0x2F334D, accent: 0x7AA2F7,
                         text: 0xC0CAF5, textSecondary: 0x9AA5CE, textTertiary: 0x565F89, bar: 0x13141C, glass: 0x0F1017, sheen: 0.05, highlight: 0.06)
        case .dracula:
            ThemePalette(background: 0x282A36, panel: 0x21222C, surface: 0x2B2D3A, card: 0x343746, elevated: 0x44475A, accent: 0xBD93F9,
                         text: 0xF8F8F2, textSecondary: 0xB9BCD0, textTertiary: 0x6272A4, bar: 0x191A21, glass: 0x14151B, sheen: 0.05, highlight: 0.06)
        case .nord:
            ThemePalette(background: 0x2E3440, panel: 0x272C36, surface: 0x313846, card: 0x3B4252, elevated: 0x434C5E, accent: 0x88C0D0,
                         text: 0xECEFF4, textSecondary: 0xD8DEE9, textTertiary: 0x8A94A8, bar: 0x20242C, glass: 0x1C2028, sheen: 0.04, highlight: 0.05)
        case .mocha:
            ThemePalette(background: 0x1E1E2E, panel: 0x181825, surface: 0x232334, card: 0x313244, elevated: 0x45475A, accent: 0xCBA6F7,
                         text: 0xCDD6F4, textSecondary: 0xA6ADC8, textTertiary: 0x7F849C, bar: 0x11111B, glass: 0x0E0E16, sheen: 0.05, highlight: 0.06)
        case .rosePine:
            ThemePalette(background: 0x191724, panel: 0x16141F, surface: 0x1F1D2E, card: 0x26233A, elevated: 0x2A273F, accent: 0xEB6F92,
                         text: 0xE0DEF4, textSecondary: 0x908CAA, textTertiary: 0x6E6A86, bar: 0x12101A, glass: 0x0E0C14, sheen: 0.045, highlight: 0.05)
        case .gruvbox:
            ThemePalette(background: 0x282828, panel: 0x1D2021, surface: 0x32302F, card: 0x3C3836, elevated: 0x504945, accent: 0xFE8019,
                         text: 0xEBDBB2, textSecondary: 0xBDAE93, textTertiary: 0x928374, bar: 0x1D2021, glass: 0x181A1B, sheen: 0.04, highlight: 0.05)
        case .solarized: .make(0x002B36, 0x00252E, 0x073642, 0x0A4452, 0x14566A, 0x2AA198, 0xEEE8D5, 0x93A1A1, 0x657B83, 0x001F27, 0x001A21, 0.04, 0.05)
        case .oneDark: .make(0x282C34, 0x21252B, 0x2C313A, 0x333842, 0x3E4451, 0x61AFEF, 0xDCDFE4, 0xABB2BF, 0x7F848E, 0x1B1E24, 0x16191E, 0.045, 0.05)
        case .monokai: .make(0x272822, 0x1E1F1C, 0x2D2E27, 0x3E3D32, 0x49483E, 0xA6E22E, 0xF8F8F2, 0xCFCFC2, 0x8F8B77, 0x1A1B17, 0x151612, 0.04, 0.05)
        case .ayu: .make(0x1F2430, 0x191E2A, 0x242936, 0x2A3040, 0x343B4D, 0xFFCC66, 0xCBCCC6, 0x9DA2AD, 0x707A8C, 0x141823, 0x10131C, 0.045, 0.05)
        case .everforest: .make(0x2D353B, 0x232A2E, 0x343F44, 0x3D484D, 0x475258, 0xA7C080, 0xD3C6AA, 0x9DA9A0, 0x859289, 0x1E2326, 0x191D20, 0.04, 0.05)
        case .kanagawa: .make(0x1F1F28, 0x16161D, 0x2A2A37, 0x363646, 0x54546D, 0x7FB4CA, 0xDCD7BA, 0xC8C093, 0x8A8980, 0x101015, 0x0C0C10, 0.045, 0.05)
        case .materialOcean: .make(0x0F111A, 0x090B10, 0x151822, 0x1A1C25, 0x292D3E, 0x82AAFF, 0xEEFFFF, 0xA6ACCD, 0x717CB4, 0x07080D, 0x050609, 0.05, 0.06)
        case .synthwave: .make(0x262335, 0x1E1B2B, 0x2A2139, 0x34294F, 0x443866, 0xFF7EDB, 0xF4EEEE, 0xB6B1C8, 0x848BBD, 0x181523, 0x120F1B, 0.07, 0.10)
        case .neon: .make(0x0A0A12, 0x07070D, 0x0E0E1A, 0x14142A, 0x1C1C38, 0x00E5FF, 0xE8F9FF, 0x9FB4C7, 0x6C7F96, 0x040408, 0x020206, 0.09, 0.16)
        case .forest: .make(0x0C1411, 0x09100E, 0x101A16, 0x15221C, 0x1D2D25, 0x3DDC97, 0xE6F4EC, 0x9DB5A8, 0x6B857A, 0x060B09, 0x040806, 0.05, 0.06)
        case .crimson: .make(0x0D0809, 0x090506, 0x120B0C, 0x1A1012, 0x24161A, 0xFF3B4E, 0xFBF1F2, 0xB5A1A4, 0x7F6B6F, 0x050304, 0x030203, 0.09, 0.15)
        case .amber: .make(0x140F0A, 0x100B07, 0x1A130D, 0x241A12, 0x30231A, 0xFFA630, 0xF8EEDF, 0xBBA891, 0x85735F, 0x0B0805, 0x070503, 0.05, 0.06)
        case .graphite: .make(0x1C1C1E, 0x161618, 0x202022, 0x2C2C2E, 0x3A3A3C, 0x0A84FF, 0xF2F2F7, 0xAEAEB2, 0x8E8E93, 0x111113, 0x0C0C0E, 0.04, 0.05)
        case .deepOcean: .make(0x08141C, 0x060F15, 0x0C1B25, 0x11242F, 0x193341, 0x2EC4B6, 0xE3F4F6, 0x92B3BA, 0x628891, 0x040B10, 0x03080B, 0.055, 0.07)
        case .custom: ThemeStore.custom.palette
        case .amethyst: .make(0x100B1A, 0x0B0813, 0x160F24, 0x1E1531, 0x2A1D44, 0xB06BFF, 0xF1E9FB, 0xB0A1C9, 0x7E6F9B, 0x07040D, 0x050309, 0.06, 0.08)
        }
    }
}

/// The theme in force. Observable, so any view that reads a colour from `ColorTokens` is redrawn by itself when the theme
/// changes (the Mac app also rebuilds its windows, which does no harm).
@Observable
final class ThemeState: @unchecked Sendable {
    var current: AppTheme = .cinematic
    var custom = CustomTheme.standard
    /// Stronger text and outlines. On when the person turns it on in the app, or the system's Increase Contrast is on.
    var userContrast = false
    var systemContrast = false
    var highContrast: Bool { userContrast || systemContrast }

    #if os(macOS)
    private var contrastObserver: NSObjectProtocol?
    init() {
        systemContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        contrastObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        }
    }
    #endif
}

enum ThemeStore {
    static let state = ThemeState()
    static var current: AppTheme { get { state.current } set { state.current = newValue } }
    static var custom: CustomTheme { get { state.custom } set { state.custom = newValue } }
    static var palette: ThemePalette { current.palette }
}
