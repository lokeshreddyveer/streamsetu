import SwiftUI

/// Music accessibility foundation: one environment bundle, the view modifiers every Music screen uses, a debounced announcer, focus helpers,
/// lyric-line helpers, a table of control labels and the checklist each screen applies in its own file.
///
/// Public names: `MusicAccessibility` (bundle, `\.musicA11y`, `View.musicAccessibilityEnvironment()`), `MusicTextStep`, `MusicHitTarget`,
/// `MusicContrast`, `MusicAnnouncer`, `MusicA11yLabels`, `MusicLyricsA11y`, `MusicA11yChecklist`, and the modifiers
/// `musicSolidWhenReducedTransparency`, `musicBackdrop`, `musicHideWhenReducedTransparency`, `musicContrastBorder`, `musicCurrentRowMarker`,
/// `musicHitTarget`, `musicScaledText`, `musicReadableOnArtwork`, `musicRestoreFocus`, `musicFocusOrder`, `musicFocusRegion`,
/// `musicDialogAccessibility`, `musicLyricLine`.
///
/// Checklist for every Music screen (apply it in your own file; the same text is in the project's dev notes):
/// 1. Motion: take animations from `MusicMotion.animation(_:reduce:)` with `\.musicA11y.reduceMotion`; with Reduce Motion on, no slides, scales,
///    parallax or looping glow; a short fade or nothing.
/// 2. Transparency: every glass, blur, wash, scrim-with-blur and ambient glow has an opaque fallback
///    (`musicSolidWhenReducedTransparency`, `musicBackdrop`, or `musicHideWhenReducedTransparency` for pure decoration).
/// 3. Contrast: borders and fills of cards, fields, chips and buttons use `musicContrastBorder`; text over artwork gets a scrim chosen with
///    `MusicContrast.scrimLevel(forBackgroundLuminance:)` (or `musicReadableOnArtwork`) and, on an accent fill, `ColorTokens.onAccent`.
/// 4. Text size: use `musicScaledText(_:)` instead of `musicText(_:)` where the text can grow; let rows and headers grow in height, never clip
///    or truncate to one fixed line without a tooltip and an accessibility label that carries the full text.
/// 5. Never colour alone: the playing row, the selected item, an error, a liked item and a download state each carry a shape, weight or glyph
///    (`musicCurrentRowMarker`, a check, a filled heart); with `differentiateWithoutColor` on, make the marker bolder.
/// 6. Labels: every icon-only control has an accessibility label from `MusicA11yLabels` (and a tooltip with the same words); toggles expose
///    their state as a value ("On", "Off") or a changing label, not only a changed icon.
/// 7. Hit targets: at least 28 pt on the Mac, 44 pt on iPhone and iPad (`musicHitTarget`); small glyphs get padding, not a bigger glyph.
/// 8. Announcements: playback changes go through `MusicAnnouncer.observe(_:)` only. Never announce progress, buffering ticks, lyric lines or
///    anything while the person is dragging the progress bar.
/// 9. Focus: after a sheet, popover, menu or dialog closes, focus returns to the control that opened it (`musicRestoreFocus`); dialogs are
///    marked `musicDialogAccessibility`; reading order follows the visual order, with `musicFocusOrder` only where it does not.
/// 10. Keyboard: every action reachable by pointer is reachable by keyboard, with a visible focus ring; Escape closes the top-most layer only.
/// 11. Lyrics: each line is one accessibility element (`musicLyricLine`), the active line is marked with the selected trait, and the
///     current-line change is never announced.
/// 12. Languages and direction: no forced uppercase, no fixed-width text boxes, leading and trailing instead of left and right.
/// 13. Check: turn on VoiceOver, Reduce Motion, Reduce Transparency, Increase Contrast, Differentiate Without Colour and the largest Music text
///     step, and walk the screen once with the keyboard only.
struct MusicAccessibility: Equatable, Sendable {
    /// The system Reduce Motion switch or the app's own "Reduce animation".
    var reduceMotion = false
    var reduceTransparency = false
    /// The system Increase Contrast switch or the app's high-contrast theme.
    var increaseContrast = false
    var differentiateWithoutColor = false
    /// The app-level text size step (macOS) that scales every `MusicTypeRole`.
    var textStep: MusicTextStep = .standard

    static let standard = MusicAccessibility()

    var textScale: CGFloat { textStep.scale }
    /// A point size after the app's text step (the role's nominal size times the step).
    func scaled(_ points: CGFloat) -> CGFloat { points * textScale }
    func scaled(_ role: MusicTypeRole) -> CGFloat { scaled(role.pointSize) }
    var minHitTarget: CGFloat { MusicHitTarget.minimum }
    /// The animation for a motion kind, nil when Reduce Motion removes it.
    func animation(_ kind: MusicMotion.Kind) -> Animation? { MusicMotion.animation(kind, reduce: reduceMotion) }
}

private struct MusicA11yKey: EnvironmentKey { static let defaultValue = MusicAccessibility.standard }

extension EnvironmentValues {
    /// The Music accessibility bundle. Inject it once near the root with `musicAccessibilityEnvironment()`; without it the value is `.standard`.
    var musicA11y: MusicAccessibility {
        get { self[MusicA11yKey.self] }
        set { self[MusicA11yKey.self] = newValue }
    }
}

private struct MusicA11yReader: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage(MusicTextStep.defaultsKey) private var stepRaw = MusicTextStep.standard.rawValue

    func body(content: Content) -> some View {
        content.environment(\.musicA11y, MusicAccessibility(
            reduceMotion: BrandMotion.reduced(systemReduceMotion),
            reduceTransparency: reduceTransparency,
            increaseContrast: contrast == .increased || ThemeStore.state.highContrast,
            differentiateWithoutColor: differentiate,
            textStep: MusicTextStep(raw: stepRaw)))
    }
}

extension View {
    /// Puts the live `MusicAccessibility` bundle in the environment (system switches plus the app's own settings).
    func musicAccessibilityEnvironment() -> some View { modifier(MusicA11yReader()) }
}

/// Reads the same switches as the bundle, so the modifiers below work even where the bundle was not injected.
private struct MusicA11yFlags: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    @Environment(\.accessibilityDifferentiateWithoutColor) var differentiate
    @Environment(\.colorSchemeContrast) private var contrast
    var reduceMotion: Bool { BrandMotion.reduced(systemReduceMotion) }
    var increaseContrast: Bool { contrast == .increased || ThemeStore.state.highContrast }
}

// MARK: - Text size step

/// The app-level text size step. macOS has no system Dynamic Type, so Music keeps its own five steps (the setting UI belongs to Settings);
/// on iOS the system Dynamic Type applies on top through `@ScaledMetric` in `musicScaledText`.
enum MusicTextStep: Int, CaseIterable, Sendable {
    case small = -1, standard = 0, large = 1, larger = 2, largest = 3

    static let defaultsKey = "music.textstep"

    /// An unknown stored value falls back to the standard step.
    init(raw: Int) { self = MusicTextStep(rawValue: raw) ?? .standard }

    /// The saved step.
    static var stored: MusicTextStep { MusicTextStep(raw: UserDefaults.standard.integer(forKey: defaultsKey)) }

    var scale: CGFloat {
        switch self {
        case .small: 0.92
        case .standard: 1
        case .large: 1.12
        case .larger: 1.25
        case .largest: 1.4
        }
    }

    /// The step's name for a picker.
    var label: String {
        switch self {
        case .small: Localized.string("Small")
        case .standard: Localized.string("Default")
        case .large: Localized.string("Large")
        case .larger: Localized.string("Larger")
        case .largest: Localized.string("Largest")
        }
    }

    /// The scaled size of a role at this step, rounded to half a point so layouts stay on a grid.
    func size(for role: MusicTypeRole) -> CGFloat { (role.pointSize * scale * 2).rounded() / 2 }
}

private extension MusicTypeRole {
    var weight: Font.Weight {
        switch self {
        case .display, .page: .bold
        case .section: .semibold
        case .card, .micro: .medium
        case .body, .secondary, .caption: .regular
        }
    }

    #if !os(macOS)
    var relativeStyle: Font.TextStyle {
        switch self {
        case .display: .largeTitle
        case .page: .title
        case .section: .title3
        case .card, .body: .body
        case .secondary: .subheadline
        case .caption: .caption
        case .micro: .caption2
        }
    }
    #endif
}

private struct MusicScaledText: ViewModifier {
    let role: MusicTypeRole
    @AppStorage(MusicTextStep.defaultsKey) private var stepRaw = MusicTextStep.standard.rawValue
    #if !os(macOS)
    @ScaledMetric private var base: CGFloat
    init(role: MusicTypeRole) {
        self.role = role
        _base = ScaledMetric(wrappedValue: role.pointSize, relativeTo: role.relativeStyle)
    }
    private var points: CGFloat { base * MusicTextStep(raw: stepRaw).scale }
    #else
    private var points: CGFloat { MusicTextStep(raw: stepRaw).size(for: role) }
    #endif

    func body(content: Content) -> some View {
        content.font(.system(size: points, weight: role.weight))
    }
}

extension View {
    /// A Music type role that follows the text step (macOS, app-level) or Dynamic Type (iOS). Use it for text that may grow.
    func musicScaledText(_ role: MusicTypeRole) -> some View { modifier(MusicScaledText(role: role)) }
}

// MARK: - Hit targets

enum MusicHitTarget {
    static let macMinimum: CGFloat = 28
    static let touchMinimum: CGFloat = 44

    /// The minimum for this platform (28 pt on the Mac, 44 pt on iPhone and iPad). Matches `MusicTokens.hitTarget`.
    static var minimum: CGFloat { MusicTokens.hitTarget }

    static func minimum(isMac: Bool) -> CGFloat { isMac ? macMinimum : touchMinimum }

    /// Padding to add on each side so a visible glyph of `visible` points reaches the minimum.
    static func padding(forVisible visible: CGFloat, minimum: CGFloat) -> CGFloat { max(0, (minimum - visible) / 2) }

    static func meets(width: CGFloat, height: CGFloat, minimum: CGFloat) -> Bool { width >= minimum && height >= minimum }
}

extension View {
    /// Makes the tappable area at least the platform minimum without changing how the control looks.
    func musicHitTarget() -> some View {
        frame(minWidth: MusicHitTarget.minimum, minHeight: MusicHitTarget.minimum).contentShape(Rectangle())
    }
}

// MARK: - Contrast maths

enum MusicContrast {
    /// WCAG minimums: normal text, large text, and UI parts; and the stronger text target used with Increase Contrast.
    static let textMinimum = 4.5
    static let largeTextMinimum = 3.0
    static let interfaceMinimum = 3.0
    static let increasedTextMinimum = 7.0

    /// WCAG contrast ratio of two relative luminances (0 black to 1 white), 1 to 21.
    static func ratio(_ a: Double, _ b: Double) -> Double {
        let hi = max(a, b), lo = min(a, b)
        return (hi + 0.05) / (lo + 0.05)
    }

    static func meets(_ a: Double, _ b: Double, minimum: Double) -> Bool { ratio(a, b) >= minimum }

    /// The lightest scrim level under which white text on a background of this luminance reaches the target ratio. The scrim is black at
    /// that opacity, so the luminance scales by (1 - opacity). Falls back to the heaviest level.
    static func scrimLevel(forBackgroundLuminance luminance: Double, increased: Bool = false) -> MusicInk.ScrimLevel {
        let target = increased ? increasedTextMinimum : textMinimum
        let clamped = min(max(luminance, 0), 1)
        for level in MusicInk.ScrimLevel.allCases where ratio(1, clamped * (1 - level.rawValue)) >= target { return level }
        return .heavy
    }

    /// The label colour on a solid fill (the app's accent-contrast helper: near-black on light fills, white on dark ones).
    static func inkOn(_ fill: Color) -> Color { ColorTokens.onAccent(fill) }
}

private struct MusicReadableOnArtwork: ViewModifier {
    let luminance: Double
    private let flags = MusicA11yFlags()

    func body(content: Content) -> some View {
        let level = MusicContrast.scrimLevel(forBackgroundLuminance: luminance, increased: flags.increaseContrast)
        content.background(MusicInk.scrim(level))
    }
}

extension View {
    /// Darkens what sits behind white text over artwork just enough to reach the contrast target (more with Increase Contrast).
    /// `backgroundLuminance` is the artwork's relative luminance where the text sits.
    func musicReadableOnArtwork(backgroundLuminance: Double) -> some View { modifier(MusicReadableOnArtwork(luminance: backgroundLuminance)) }
}

// MARK: - Reduce Transparency

private struct MusicSolidWhenReduced: ViewModifier {
    let solid: Color
    let cornerRadius: CGFloat
    private let flags = MusicA11yFlags()

    func body(content: Content) -> some View {
        content.background {
            if flags.reduceTransparency {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(solid).allowsHitTesting(false)
            }
        }
    }
}

private struct MusicBackdrop<Translucent: View>: ViewModifier {
    let solid: Color
    let cornerRadius: CGFloat
    let translucent: Translucent
    private let flags = MusicA11yFlags()

    func body(content: Content) -> some View {
        content.background {
            if flags.reduceTransparency {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(solid).allowsHitTesting(false)
            } else {
                translucent.allowsHitTesting(false)
            }
        }
    }
}

private struct MusicHideWhenReduced: ViewModifier {
    private let flags = MusicA11yFlags()
    func body(content: Content) -> some View {
        if flags.reduceTransparency { EmptyView() } else { content }
    }
}

extension View {
    /// Adds an opaque layer behind the content when Reduce Transparency is on. Use where translucent chrome is already drawn by the
    /// content itself (a material fill on the view): the solid layer sits behind it and the content should drop its own fill via `musicBackdrop`.
    func musicSolidWhenReducedTransparency(_ solid: Color = ColorTokens.surface, cornerRadius: CGFloat = MusicCorner.card) -> some View {
        modifier(MusicSolidWhenReduced(solid: solid, cornerRadius: cornerRadius))
    }

    /// A background that is glass, blur or a wash normally and a flat opaque surface when Reduce Transparency is on.
    func musicBackdrop<Translucent: View>(solid: Color = ColorTokens.surface, cornerRadius: CGFloat = MusicCorner.card,
                                          @ViewBuilder translucent: () -> Translucent) -> some View {
        modifier(MusicBackdrop(solid: solid, cornerRadius: cornerRadius, translucent: translucent()))
    }

    /// Removes purely decorative see-through layers (ambient glow, detail wash) when Reduce Transparency is on.
    func musicHideWhenReducedTransparency() -> some View { modifier(MusicHideWhenReduced()) }
}

// MARK: - Increase Contrast

private struct MusicContrastBorder: ViewModifier {
    let cornerRadius: CGFloat
    let always: Bool
    private let flags = MusicA11yFlags()

    func body(content: Content) -> some View {
        content.overlay {
            if always || flags.increaseContrast {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(ColorTokens.textSecondary, lineWidth: flags.increaseContrast ? 1.5 : 1)
                    .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    /// A clear outline for cards, fields, chips and buttons when Increase Contrast (or the high-contrast theme) is on.
    func musicContrastBorder(cornerRadius: CGFloat = MusicCorner.card, always: Bool = false) -> some View {
        modifier(MusicContrastBorder(cornerRadius: cornerRadius, always: always))
    }
}

// MARK: - Current row marker

/// What marks the playing row besides colour: a leading bar (wider with Differentiate Without Colour), a heavier weight, a speaker or pause
/// glyph where a view asks for one (`MusicCurrentRowGlyph`), and the VoiceOver value.
private struct MusicCurrentRowMarker: ViewModifier {
    let isCurrent: Bool
    let isPlaying: Bool
    private let flags = MusicA11yFlags()

    func body(content: Content) -> some View {
        content
            .fontWeight(isCurrent ? .semibold : nil)
            .overlay(alignment: .leading) {
                if isCurrent {
                    Capsule()
                        .fill(ColorTokens.accent)
                        .frame(width: flags.differentiate ? 4 : 3)
                        .padding(.vertical, MusicSpace.xxs)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityValue(isCurrent ? (isPlaying ? MusicA11yLabels.nowPlaying : MusicA11yLabels.paused) : "")
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// What a track row shows, as a pure matrix: hover draws the play button and a subtle fill, the current row a speaker glyph (animated only while
/// playing) and accent weight, and the keyboard ring appears only for keyboard focus, never after a click.
enum MusicRowMarkerState {
    enum Leading: Equatable, Sendable { case number, play, speaker, pause }

    static func leading(isCurrent: Bool, isPlaying: Bool, hovering: Bool) -> Leading {
        if hovering { return .play }
        if isCurrent { return isPlaying ? .speaker : .pause }
        return .number
    }
    static func animatesGlyph(isCurrent: Bool, isPlaying: Bool, reduceMotion: Bool) -> Bool { isCurrent && isPlaying && !reduceMotion }
    static func showsFocusRing(focused: Bool, keyboard: Bool) -> Bool { focused && keyboard }
}

/// The glyph for the playing row's number slot: a speaker while playing, a pause mark while paused.
struct MusicCurrentRowGlyph: View {
    let isPlaying: Bool
    var body: some View {
        Image(systemName: isPlaying ? "speaker.wave.2.fill" : "pause.fill")
            .font(.system(size: MusicIconSize.small, weight: .semibold))
            .foregroundStyle(ColorTokens.accent)
            .symbolEffect(.variableColor.iterative, isActive: isPlaying && !BrandMotion.reduced(false))
            .accessibilityHidden(true)
    }
}

extension View {
    /// Marks the row of the current track without relying on colour (bar, weight, VoiceOver value and selected trait).
    func musicCurrentRowMarker(isCurrent: Bool, isPlaying: Bool = true) -> some View {
        modifier(MusicCurrentRowMarker(isCurrent: isCurrent, isPlaying: isPlaying))
    }
}

// MARK: - Announcements

/// Speaks playback changes to VoiceOver. Feed it a snapshot whenever the player's state may have changed; it compares with the last one and
/// speaks only a real change of track or of play/pause. Position never enters the snapshot, so progress ticks cannot announce. While the
/// person is seeking nothing is spoken and the snapshot is not recorded. Announcements closer together than `window` are merged: the
/// latest one wins and is spoken once the window has passed; the same words are never repeated inside the window.
@MainActor
final class MusicAnnouncer {
    struct Snapshot: Equatable {
        var trackID: String?
        var title: String
        var artist: String
        var isPlaying: Bool
        var isSeeking: Bool
        init(trackID: String?, title: String = "", artist: String = "", isPlaying: Bool, isSeeking: Bool = false) {
            self.trackID = trackID; self.title = title; self.artist = artist; self.isPlaying = isPlaying; self.isSeeking = isSeeking
        }
    }

    static let shared = MusicAnnouncer()

    let window: TimeInterval
    private let clock: () -> TimeInterval
    private let post: (String) -> Void
    private let autoFlush: Bool
    private var last: Snapshot?
    private var pending: String?
    private var lastText: String?
    private var lastPostedAt: TimeInterval?
    private var flushTask: Task<Void, Never>?

    init(window: TimeInterval = 0.8,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         autoFlush: Bool = true,
         post: @escaping (String) -> Void = MusicAnnouncer.systemPost) {
        self.window = window; self.clock = clock; self.autoFlush = autoFlush; self.post = post
    }

    nonisolated static func systemPost(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }

    /// The text for a change from `old` to `new`, or nil when nothing should be spoken.
    nonisolated static func text(from old: Snapshot, to new: Snapshot) -> String? {
        let trackChanged = new.trackID != nil && new.trackID != old.trackID
        if trackChanged {
            guard new.isPlaying else { return nil }
            if new.title.isEmpty { return Localized.string("Now playing") }
            if new.artist.isEmpty { return Localized.string("Playing %@", new.title) }
            return Localized.string("Now playing, %1$@ by %2$@", new.title, new.artist)
        }
        if new.isPlaying != old.isPlaying { return new.isPlaying ? Localized.string("Playing") : Localized.string("Paused") }
        return nil
    }

    /// Call on any player state change. The first snapshot only sets the baseline.
    func observe(_ snapshot: Snapshot) {
        if snapshot.isSeeking { return }
        guard let previous = last else { last = snapshot; return }
        last = snapshot
        guard let text = Self.text(from: previous, to: snapshot) else { return }
        enqueue(text)
    }

    /// A one-off message from a screen (for example "Added to queue"). Same debounce rules.
    func announce(_ text: String) { enqueue(text) }

    /// Speaks the held message if the window has passed. Called by the timer, and by tests.
    func flushPending() {
        guard let text = pending else { return }
        let now = clock()
        if let at = lastPostedAt, now - at < window { scheduleFlush(after: window - (now - at)); return }
        pending = nil
        speak(text, at: now)
    }

    /// Forgets the baseline (use when the player is torn down) and drops anything held.
    func reset() { last = nil; pending = nil; flushTask?.cancel(); flushTask = nil }

    private func enqueue(_ text: String) {
        let now = clock()
        if text == lastText, let at = lastPostedAt, now - at < window { pending = nil; return }
        if let at = lastPostedAt, now - at < window {
            pending = text
            scheduleFlush(after: window - (now - at))
            return
        }
        pending = nil
        speak(text, at: now)
    }

    private func speak(_ text: String, at now: TimeInterval) {
        lastText = text
        lastPostedAt = now
        post(text)
    }

    private func scheduleFlush(after seconds: TimeInterval) {
        guard autoFlush else { return }
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.05, seconds)))
            guard !Task.isCancelled else { return }
            self?.flushPending()
        }
    }
}

// MARK: - Focus

private struct MusicRestoreFocus<Value: Hashable>: ViewModifier {
    let isPresented: Bool
    let target: Value
    var focus: FocusState<Value?>.Binding

    func body(content: Content) -> some View {
        content.onChange(of: isPresented) { was, now in
            guard was, !now else { return }
            Task { @MainActor in
                await Task.yield()
                focus.wrappedValue = target
            }
        }
    }
}

extension View {
    /// Returns keyboard focus to `target` after a sheet, popover, menu or dialog closes (`isPresented` goes from true to false).
    func musicRestoreFocus<Value: Hashable>(after isPresented: Bool, to target: Value, focus: FocusState<Value?>.Binding) -> some View {
        modifier(MusicRestoreFocus(isPresented: isPresented, target: target, focus: focus))
    }

    /// Reading and tab order where it differs from the visual order: higher numbers are read first.
    func musicFocusOrder(_ priority: Double) -> some View { accessibilitySortPriority(priority) }

    /// A region the keyboard and VoiceOver treat as a group (sidebar, content, context panel), with a name.
    func musicFocusRegion(_ label: String) -> some View {
        focusSection().accessibilityElement(children: .contain).accessibilityLabel(label)
    }

    /// Marks a sheet, popover or dialog as modal for VoiceOver and names it.
    func musicDialogAccessibility(_ label: String) -> some View {
        accessibilityElement(children: .contain).accessibilityLabel(label).accessibilityAddTraits(.isModal)
    }
}

// MARK: - Lyrics

enum MusicLyricsA11y {
    /// "1:05" for a time in seconds; negative or non-finite values read as 0:00.
    static func timeLabel(_ seconds: Double) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds)) : 0
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct MusicLyricLineAccessibility: ViewModifier {
    let text: String
    let startSeconds: Double?
    let isActive: Bool
    let onSeek: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .accessibilityValue(startSeconds.map { Localized.string("At %@", MusicLyricsA11y.timeLabel($0)) } ?? "")
            .accessibilityAddTraits(isActive ? [.isStaticText, .isSelected] : .isStaticText)
            .accessibilityAction(named: Text("Play from here")) { onSeek?() }
    }
}

extension View {
    /// One accessibility element per lyric line: the words, the start time as the value, the selected trait on the active line, and a
    /// "Play from here" action. Pass `isActive` as a plain Bool so the line re-renders only when it changes, and never post announcements for
    /// line changes.
    func musicLyricLine(_ text: String, startSeconds: Double?, isActive: Bool, onSeek: (() -> Void)? = nil) -> some View {
        modifier(MusicLyricLineAccessibility(text: text, startSeconds: startSeconds, isActive: isActive, onSeek: onSeek))
    }
}

// MARK: - Labels

/// One wording for each control, shared by the accessibility label and the tooltip. Read at call time, so they follow the chosen language.
enum MusicA11yLabels {
    static var play: String { Localized.string("Play") }
    static var pause: String { Localized.string("Pause") }
    static var next: String { Localized.string("Next track") }
    static var previous: String { Localized.string("Previous track") }
    static var shuffle: String { Localized.string("Shuffle") }
    static var `repeat`: String { Localized.string("Repeat") }
    static var like: String { Localized.string("Add to Favourites") }
    static var unlike: String { Localized.string("Remove from Favourites") }
    static var queue: String { Localized.string("Queue") }
    static var addToQueue: String { Localized.string("Add to queue") }
    static var lyrics: String { Localized.string("Lyrics") }
    static var volume: String { Localized.string("Volume") }
    static var mute: String { Localized.string("Mute") }
    static var seek: String { Localized.string("Seek") }
    static var more: String { Localized.string("More options") }
    static var close: String { Localized.string("Close") }
    static var back: String { Localized.string("Back") }
    static var nowPlaying: String { Localized.string("Now playing") }
    static var paused: String { Localized.string("Paused") }

    static var openPlayerHint: String { Localized.string("Opens the full player") }
    static var openQueueHint: String { Localized.string("Opens the queue") }
    static var lyricsHint: String { Localized.string("Shows the words as the song plays") }
    static var nextHint: String { Localized.string("Plays the next song in the queue") }
    static var previousHint: String { Localized.string("Plays the previous song or restarts this one") }

    /// "Now playing, Title by Artist" for the player bar's summary element.
    static func nowPlaying(title: String, artist: String) -> String {
        artist.isEmpty ? Localized.string("Playing %@", title) : Localized.string("Now playing, %1$@ by %2$@", title, artist)
    }
}

/// The checklist as plain sentences, one per item (the doc comment at the top of this file carries the same list; tests keep it non-empty).
enum MusicA11yChecklist {
    static let items: [String] = [
        "Motion follows Reduce Motion through MusicMotion.animation with the bundle's reduceMotion.",
        "Glass, blur, wash and glow have an opaque fallback under Reduce Transparency.",
        "Borders and fills strengthen under Increase Contrast; text over artwork gets a scrim chosen by contrast.",
        "Text uses musicScaledText and the layout grows with it.",
        "State is never colour alone: marker, glyph or weight as well.",
        "Icon-only controls carry a label from MusicA11yLabels and a matching tooltip.",
        "Hit targets are at least 28 pt on the Mac and 44 pt on iPhone and iPad.",
        "Playback changes are announced through MusicAnnouncer only, never on progress or while seeking.",
        "Focus returns to the opener after sheets, popovers and dialogs; dialogs are marked modal.",
        "Everything works from the keyboard with a visible focus ring.",
        "Lyric lines are single elements with the active line selected, never announced per frame.",
        "No forced uppercase or fixed-width text; leading and trailing, not left and right.",
        "Check with VoiceOver, all four system switches and the largest text step.",
    ]
}
