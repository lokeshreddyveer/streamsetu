import SwiftUI

// The Music button system: one set of styles for every button in Music, so a button looks and behaves the same on every page.
//
// Names (stable): `MusicButtonVariant` (primary, secondary, tertiary, destructive, icon, chip, hero), `MusicButtonSize` (compact 28, regular 32,
// large 40), `MusicButtonMetrics`, `MusicButtonLogic`, `MusicButtonStyle`, `View.musicButton(_:size:selected:accentText:)`,
// `ButtonStyle.music(_:)`, `MusicButton`, `MusicIconButton`, `MusicToggleChip`.
//
// Rules: a filled button is the accent with the app's accent-contrast label and no glow or blur shadow; one primary action per section; the corner
// is a capsule for filled, glass and chip buttons and `MusicCorner.control` for the quiet ones; hover, pressed and disabled are visible; the focus ring shows for the keyboard only;
// Increase Contrast adds an outline; Reduce Motion drops the press scale; the hit area is at least `MusicHitTarget.minimum` (28 pt Mac, 44 pt touch).

enum MusicButtonVariant: CaseIterable, Sendable {
    /// The one main action of a section: accent fill.
    case primary
    /// A neutral fill with a hairline edge.
    case secondary
    /// Plain text; the accent shows on hover.
    case tertiary
    /// Removes or clears something: danger-tinted.
    case destructive
    /// A symbol alone, with a hover fill.
    case icon
    /// A filter or toggle chip (capsule).
    case chip
    /// The large play action of a hero header.
    case hero
    /// A symbol alone on a round glass disc: the icon buttons of a page header (heart, add to playlist, share, more).
    case glassIcon
}

enum MusicButtonSize: CaseIterable, Sendable {
    case compact, regular, large

    /// The height scale, from the spacing tokens: 28, 32 and 40 pt.
    var height: CGFloat {
        switch self {
        case .compact: MusicSpace.xl + MusicSpace.xxs
        case .regular: MusicSpace.xxl
        case .large: MusicSpace.huge
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .compact: MusicSpace.sm
        case .regular: MusicSpace.md
        case .large: MusicSpace.lg
        }
    }

    var role: MusicTypeRole { self == .compact ? .secondary : .card }
    var iconSize: CGFloat { self == .large ? MusicIconSize.large : MusicIconSize.medium }
    var corner: CGFloat { self == .large ? MusicCorner.controlLarge : MusicCorner.control }
}

enum MusicButtonState: Equatable, Sendable { case rest, hover, pressed, disabled }

/// Pure sizes: the visible height and the hit area on each platform.
enum MusicButtonMetrics {
    /// The visible height: the scale value, raised to the platform hit-target minimum.
    static func height(_ size: MusicButtonSize, minimum: CGFloat = MusicHitTarget.minimum) -> CGFloat { max(size.height, minimum) }

    /// The side of an icon button: a square at the size's height.
    static func iconSide(_ size: MusicButtonSize, minimum: CGFloat = MusicHitTarget.minimum) -> CGFloat { height(size, minimum: minimum) }

    static func meetsHitTarget(_ size: MusicButtonSize, minimum: CGFloat) -> Bool { height(size, minimum: minimum) >= minimum }

    /// The pill buttons: the accent ones, the glass ones, chips and the round icon discs. Quiet text and plain icon buttons keep the small corner.
    static func usesCapsule(_ variant: MusicButtonVariant) -> Bool {
        switch variant { case .primary, .hero, .secondary, .chip, .glassIcon, .destructive: true; case .tertiary, .icon: false }
    }

    static func corner(_ variant: MusicButtonVariant, size: MusicButtonSize) -> CGFloat { size.corner }
}

/// Pure choices behind the look.
enum MusicButtonLogic {
    static func state(enabled: Bool, pressed: Bool, hovering: Bool) -> MusicButtonState {
        if !enabled { return .disabled }
        if pressed { return .pressed }
        return hovering ? .hover : .rest
    }

    /// Filled variants carry an accent fill.
    static func isFilled(_ variant: MusicButtonVariant, selected: Bool = false) -> Bool {
        switch variant {
        case .primary, .hero: true
        case .chip, .secondary, .tertiary, .destructive, .icon, .glassIcon: false
        }
    }

    /// Glass: a translucent disc or pill with a hairline edge and a soft lift on hover (secondary, chips at rest, round icon buttons).
    static func isGlass(_ variant: MusicButtonVariant) -> Bool { variant == .secondary || variant == .glassIcon }

    /// A chosen chip is TONAL, not filled: a tint of the accent, an accent edge and a check (see `MusicChip`), with the label in the normal text colour. A solid accent
    /// block on every chosen chip shouted over the content it filters, and its contrast depended on the accent; the tint keeps the label readable on any theme.
    static func isTonal(_ variant: MusicButtonVariant, selected: Bool) -> Bool { variant == .chip && selected }

    /// The tint of the accent behind a chosen chip, by state.
    static func tonalOpacity(_ state: MusicButtonState) -> Double {
        switch state {
        case .rest: 0.18
        case .hover: 0.26
        case .pressed: 0.34
        case .disabled: 0.1
        }
    }

    /// How much of the accent shows in each state.
    static func fillOpacity(_ state: MusicButtonState) -> Double {
        switch state {
        case .rest: 1
        case .hover: 0.92
        case .pressed: 0.8
        case .disabled: 0.35
        }
    }

    /// The label colour on a filled button: the app's accent-contrast helper.
    static func labelInk(fill: Color) -> Color { MusicContrast.inkOn(fill) }

    /// The keyboard-only focus ring (the shared Music rule: focused, and focus came from the keyboard).
    static func showsFocusRing(focused: Bool, keyboard: Bool) -> Bool { MusicRowMarkerState.showsFocusRing(focused: focused, keyboard: keyboard) }

    /// The press scale; none under Reduce Motion.
    static func pressScale(pressed: Bool, reduceMotion: Bool) -> CGFloat { pressed && !reduceMotion ? 0.97 : 1 }

    /// A small rise on hover for the pills and discs; none under Reduce Motion.
    static func hoverScale(hovering: Bool, enabled: Bool, reduceMotion: Bool) -> CGFloat { hovering && enabled && !reduceMotion ? 1.025 : 1 }
}

struct MusicButtonStyle: ButtonStyle {
    var variant: MusicButtonVariant = .secondary
    var size: MusicButtonSize = .regular
    var selected = false
    /// A secondary button whose text is the accent.
    var accentText = false

    func makeBody(configuration: Configuration) -> some View {
        MusicButtonBody(configuration: configuration, variant: variant, size: size, selected: selected, accentText: accentText)
    }
}

extension ButtonStyle where Self == MusicButtonStyle {
    static func music(_ variant: MusicButtonVariant = .secondary, size: MusicButtonSize = .regular, selected: Bool = false, accentText: Bool = false) -> MusicButtonStyle {
        MusicButtonStyle(variant: variant, size: size, selected: selected, accentText: accentText)
    }
}

extension View {
    /// The Music button look: `Button("Play") { }.musicButton(.primary)`. Also turns off the system focus effect; the style draws its own keyboard ring.
    func musicButton(_ variant: MusicButtonVariant = .secondary, size: MusicButtonSize = .regular, selected: Bool = false, accentText: Bool = false) -> some View {
        buttonStyle(MusicButtonStyle(variant: variant, size: size, selected: selected, accentText: accentText)).focusEffectDisabled()
    }
}

private struct MusicButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let variant: MusicButtonVariant
    let size: MusicButtonSize
    let selected: Bool
    let accentText: Bool
    @Environment(\.reddyAccent) private var accent
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var hovering = false
    @State private var keyboard = false

    private var reduce: Bool { BrandMotion.reduced(systemReduceMotion) }
    private var state: MusicButtonState { MusicButtonLogic.state(enabled: enabled, pressed: configuration.isPressed, hovering: hovering) }
    private var filled: Bool { MusicButtonLogic.isFilled(variant, selected: selected) }
    private var tonal: Bool { MusicButtonLogic.isTonal(variant, selected: selected) }
    private var height: CGFloat { MusicButtonMetrics.height(size) }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: MusicButtonMetrics.usesCapsule(variant) ? height / 2 : size.corner, style: .continuous)
    }

    /// The glow of a filled button and the lift of a glass one. Both are theme colours (the accent, the app background), never fixed black or white.
    private var shadow: (color: Color, radius: CGFloat, y: CGFloat) {
        guard state != .disabled else { return (.clear, 0, 0) }
        if filled { return (accent.opacity(state == .hover ? 0.46 : state == .pressed ? 0.16 : 0.28), state == .hover ? 18 : 11, state == .pressed ? 2 : 5) }
        if MusicButtonLogic.isGlass(variant) { return (ColorTokens.background.opacity(state == .hover ? 0.55 : 0.3), state == .hover ? 12 : 6, state == .hover ? 4 : 2) }
        return (.clear, 0, 0)
    }

    private var fill: Color {
        if filled { return accent.opacity(MusicButtonLogic.fillOpacity(state)) }
        if tonal { return accent.opacity(MusicButtonLogic.tonalOpacity(state)) }
        switch variant {
        case .destructive: return ColorTokens.danger.opacity(state == .hover ? 0.2 : state == .pressed ? 0.28 : 0.12)
        case .secondary, .chip, .glassIcon: return ColorTokens.elevated.opacity(variant == .chip ? 1 : (state == .hover ? 0.78 : 0.58))
        case .tertiary, .icon, .primary, .hero: return .clear
        }
    }

    /// A quiet wash over neutral fills while hovered or pressed.
    private var wash: Color {
        guard variant == .secondary || variant == .icon || variant == .chip || variant == .glassIcon, !filled else { return .clear }
        switch state { case .hover: return ColorTokens.line; case .pressed: return ColorTokens.lineStrong; default: return .clear }
    }

    private var ink: Color {
        let base: Color
        if filled { base = MusicButtonLogic.labelInk(fill: accent) }
        else {
            switch variant {
            case .destructive: base = ColorTokens.danger
            case .tertiary: base = state == .hover || state == .pressed ? accent : ColorTokens.textSecondary
            case .icon: base = state == .hover || state == .pressed ? ColorTokens.textPrimary : ColorTokens.textSecondary
            case .secondary: base = accentText ? accent : ColorTokens.textPrimary
            case .glassIcon: base = state == .hover || state == .pressed ? ColorTokens.textPrimary : ColorTokens.textPrimary.opacity(0.88)
            // A chip at rest is quiet text that comes up on hover; a chosen one is the full text colour (its accent is the tint, the edge and the check).
            case .chip: base = tonal || state == .hover || state == .pressed ? ColorTokens.textPrimary : ColorTokens.textSecondary
            case .primary, .hero: base = ColorTokens.textPrimary
            }
        }
        return state == .disabled ? base.opacity(0.5) : base
    }

    private var edge: Color? {
        guard !filled else { return nil }
        switch variant {
        case .secondary, .glassIcon: return state == .hover || state == .pressed ? ColorTokens.lineStrong : ColorTokens.line
        case .chip: return tonal ? accent.opacity(state == .disabled ? 0.3 : 0.65) : (state == .hover || state == .pressed ? ColorTokens.lineStrong : ColorTokens.line)
        default: return nil
        }
    }

    var body: some View {
        configuration.label
            .font(variant == .icon || variant == .glassIcon ? Font.system(size: size.iconSize, weight: .medium) : size.role.font)
            .lineLimit(1)
            .foregroundStyle(ink)
            .padding(.horizontal, variant == .icon || variant == .glassIcon ? 0 : size.horizontalPadding + (variant == .hero || variant == .primary ? MusicSpace.xxs : 0))
            // A chip is never a sliver: even "All" is wide enough to hit (and the hit area is the whole capsule).
            .frame(minWidth: variant == .icon || variant == .glassIcon ? MusicButtonMetrics.iconSide(size) : (variant == .chip ? MusicSpace.huge : nil), minHeight: height)
            .background {
                ZStack {
                    // Glass: a blur of what is behind, under the tinted fill.
                    if MusicButtonLogic.isGlass(variant) { shape.fill(.ultraThinMaterial) }
                    shape.fill(fill)
                    // A filled button is a soft vertical gradient (lighter at the top), the way a lit surface reads.
                    if filled { shape.fill(LinearGradient(colors: [Color.white.opacity(state == .pressed ? 0.04 : 0.2), Color.white.opacity(0)], startPoint: .top, endPoint: .center)) }
                }
            }
            .overlay { shape.fill(wash).allowsHitTesting(false) }
            // The specular rim: a bright hairline along the top edge that fades down the sides.
            .overlay {
                if filled { shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.5), Color.white.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: 1).allowsHitTesting(false) }
                else if MusicButtonLogic.isGlass(variant) { shape.strokeBorder(LinearGradient(colors: [ColorTokens.lineStrong, ColorTokens.line.opacity(0.5)], startPoint: .top, endPoint: .bottom), lineWidth: 1).allowsHitTesting(false) }
            }
            .shadow(color: shadow.color, radius: shadow.radius, y: shadow.y)
            .overlay { if let edge, !MusicButtonLogic.isGlass(variant) { shape.strokeBorder(edge, lineWidth: 1).allowsHitTesting(false) } }
            .musicContrastBorder(cornerRadius: size.corner, always: false)
            .overlay {
                if MusicButtonLogic.showsFocusRing(focused: focused, keyboard: keyboard) {
                    shape.strokeBorder(filled ? ColorTokens.textPrimary : accent, lineWidth: 2).padding(-MusicSpace.xxs / 2).allowsHitTesting(false)
                }
            }
            .contentShape(shape)
            .scaleEffect(MusicButtonLogic.pressScale(pressed: configuration.isPressed, reduceMotion: reduce) * (filled || MusicButtonLogic.isGlass(variant) ? MusicButtonLogic.hoverScale(hovering: hovering, enabled: enabled, reduceMotion: reduce) : 1))
            .animation(MusicMotion.animation(.press, reduce: reduce), value: configuration.isPressed)
            .animation(MusicMotion.animation(.hover, reduce: reduce), value: hovering)
            .onChange(of: configuration.isPressed) { _, down in if down { PremiumFeedback.tick() } }
            .onHover { hovering = $0 }
            .onChange(of: focused) { _, now in keyboard = now && !hovering }
    }
}

// MARK: - Views

/// atlas: the caller passes the Atlas id of the control in `atlas`, and it is applied to the button here.
/// A text button with an optional leading symbol and a spinner while `busy`.
struct MusicButton: View {
    let title: String
    var systemImage: String?
    var variant: MusicButtonVariant = .secondary
    var size: MusicButtonSize = .regular
    var busy = false
    var role: ButtonRole?
    var atlas: String?
    var accessibilityLabel: String?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: MusicSpace.xs) {
                if busy { ProgressView().controlSize(.small) }
                else if let systemImage { Image(systemName: systemImage).font(.system(size: size.iconSize, weight: .semibold)).accessibilityHidden(true) }
                Text(title.loc)
            }
        }
        .musicButton(variant, size: size)
        .accessibilityLabel(Text((accessibilityLabel ?? title).loc))
        .atlasOptional(atlas)
    }
}

/// atlas: the caller passes the Atlas id of the control in `atlas`, and it is applied to the button here.
/// A symbol-only button with a tooltip and a spoken label (both the same words).
struct MusicIconButton: View {
    let systemImage: String
    let label: String
    var size: MusicButtonSize = .compact
    var atlas: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: systemImage).accessibilityHidden(true) }
            .musicButton(.icon, size: size)
            .accessibilityLabel(Text(label.loc)).help(Text(label.loc))
            .atlasOptional(atlas)
    }
}

/// atlas: the caller passes the Atlas id of the control in `atlas`, and it is applied to the chip here.
/// A filter or toggle chip. A selected chip is filled and also shows a check, so state never rests on colour alone.
struct MusicToggleChip: View {
    let title: String
    @Binding var isOn: Bool
    var atlas: String?

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: MusicSpace.xxs) {
                if isOn { Image(systemName: "checkmark").font(.system(size: MusicIconSize.small, weight: .bold)).accessibilityHidden(true) }
                Text(title.loc)
            }
        }
        .musicButton(.chip, size: .compact, selected: isOn)
        .accessibilityLabel(Text(title.loc)).accessibilityValue(Text(isOn ? "On" : "Off")).accessibilityAddTraits(isOn ? .isSelected : [])
        .atlasOptional(atlas)
    }
}
