import SwiftUI

/// What the toggles and the consent step do, with no views, so it can be tested. Used by Settings AND the first-open prompt, over the one shared
/// store, so the two never disagree. Nothing turns on without the explanation being confirmed first.
@MainActor @Observable
final class EnhancementToggleModel {
    let runtime: EnhancementRuntime
    /// The enhancement whose explanation is showing (an alert); nil when none.
    var pending: PageEnhancement?
    /// A turned-off or turned-on choice that needs the page to reload to take effect (shown with a Reload button).
    private(set) var reloadHint = false

    init(runtime: EnhancementRuntime = .shared) { self.runtime = runtime }

    var store: EnhancementStore { runtime.store }
    /// Kids profile in use or app locked: the controls are not offered.
    var isRestricted: Bool { runtime.isRestricted() }

    func isOn(_ e: PageEnhancement) -> Bool { store.isActive(e) }

    /// Off needs no question; on always asks first (even when an earlier agreement is on record).
    func set(_ e: PageEnhancement, on: Bool) {
        guard !isRestricted else { return }
        if on { if !store.isActive(e) { pending = e } }
        else if store.isEnabled(e) { store.disable(e); reloadHint = true }
    }

    func confirm() {
        guard let e = pending, !isRestricted else { pending = nil; return }
        pending = nil
        store.grant(e); reloadHint = true
    }

    func cancel() { pending = nil }
    func clearReloadHint() { reloadHint = false }
}

/// The consent explanation as an alert, attached once per place that shows the toggles.
private struct EnhancementConsentAlert: ViewModifier {
    @Bindable var model: EnhancementToggleModel
    func body(content: Content) -> some View {
        content.alert(Text(verbatim: model.pending.map { Localized.string($0.consentTitle) } ?? ""),
                      isPresented: Binding(get: { model.pending != nil }, set: { if !$0 { model.cancel() } })) {
            Button("Cancel", role: .cancel) { model.cancel() }.atlas("control.enhancement.consentCancel")
            Button("Turn On") { model.confirm() }.atlas("control.enhancement.consentConfirm")
        } message: { Text(verbatim: model.pending.map { Localized.string($0.consentMessage) } ?? "") }
    }
}

extension View {
    func enhancementConsentAlert(_ model: EnhancementToggleModel) -> some View { modifier(EnhancementConsentAlert(model: model)) }
}

/// The opaque themed card surface shared by the first-open card and the Settings group: same fill, sheen, hairline, highlight and layered
/// shadow as the Services panel (`ServicesPanelSurface`), at a chosen radius. Only theme tokens, so every theme and appearance follows.
struct PremiumCardSurface: View {
    var radius: CGFloat = LayoutTokens.radiusPanel
    var elevated = true
    @Environment(\.reddyAccent) private var accent
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.fill(ColorTokens.panel)
            shape.fill(LinearGradient(colors: [accent.opacity(0.07), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.45)))
            GlossSheen(cornerRadius: radius, streak: false)
        }
        .overlay(shape.strokeBorder(ColorTokens.lineStrong, lineWidth: 1))
        .overlay(shape.inset(by: 1).strokeBorder(LinearGradient(colors: [Color.white.opacity(0.07), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.3)), lineWidth: 1))
        .compositingGroup()
        .shadow(color: .black.opacity(elevated ? 0.45 : 0), radius: 30, y: 16)
        .shadow(color: .black.opacity(elevated ? 0.30 : 0), radius: 8, y: 3)
        .shadow(color: .black.opacity(elevated ? 0.50 : 0.18), radius: 1, y: 0.5)
    }
}

/// Quiet (wash on hover) or prominent (accent filled) button with premium hover and pressed states and a keyboard focus ring.
private struct PremiumButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.reddyAccent) private var accent
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let pressed = configuration.isPressed
        configuration.label
            .font(Typography.bodyMedium)
            .foregroundStyle(prominent ? Color.white : ColorTokens.textPrimary)
            .padding(.horizontal, 16).frame(minHeight: 32)
            .background {
                if prominent {
                    shape.fill(accent.opacity(pressed ? 0.78 : hovering ? 1 : 0.92))
                        .overlay(shape.fill(LinearGradient(colors: [Color.white.opacity(0.18), .clear], startPoint: .top, endPoint: .center)))
                        .shadow(color: accent.opacity(hovering ? 0.45 : 0.28), radius: hovering ? 8 : 5, y: 2)
                } else {
                    shape.fill(ColorTokens.textPrimary.opacity(pressed ? 0.11 : hovering ? 0.07 : 0))
                }
            }
            .overlay(shape.strokeBorder(prominent ? Color.white.opacity(0.16) : ColorTokens.line, lineWidth: 0.5))
            .contentShape(shape)
            .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
            .opacity(enabled ? 1 : 0.45)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : AnimationTokens.hover, value: hovering)
            .animation(reduceMotion ? nil : AnimationTokens.press, value: pressed)
    }
}

/// One toggle for one enhancement: icon tile, title, description, themed switch and the consent state line. `inPrompt` only changes the Atlas
/// id, because the same control sits in two places.
struct EnhancementToggleRow: View {
    let enhancement: PageEnhancement
    @Bindable var model: EnhancementToggleModel
    var inPrompt = false
    @Environment(\.reddyAccent) private var accent

    private var symbol: String { enhancement == .adSkip ? "forward.end.alt.fill" : "scissors" }
    private var consentLine: String? {
        guard model.store.hasConsent(enhancement), let date = model.store.consent(enhancement)?.date else { return nil }
        return Localized.string("Consent given on %@", date.formatted(date: .abbreviated, time: .omitted))
    }

    var body: some View {
        let on = model.isOn(enhancement)
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(on ? accent : ColorTokens.textSecondary)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? accent.opacity(0.16) : ColorTokens.textPrimary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(ColorTokens.line, lineWidth: 0.5))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(enhancement.title.loc).font(Typography.bodyMedium).foregroundStyle(ColorTokens.textPrimary)
                Text(enhancement.summary.loc).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let consentLine {
                    Text(verbatim: consentLine).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { model.isOn(enhancement) }, set: { model.set(enhancement, on: $0) }))
                .labelsHidden().toggleStyle(.switch).tint(accent)
                .atlasCovers("control.settings.enhancementAdSkip")      // the id is chosen by place and kind in EnhancementToggleAtlas
                .accessibilityLabel(Text(enhancement.title.loc))
                .accessibilityHint(Text(enhancement.summary.loc))
                .modifier(EnhancementToggleAtlas(enhancement: enhancement, inPrompt: inPrompt))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(minHeight: 48)
    }
}

/// The toggles as one grouped, themed card with hairline dividers.
struct EnhancementToggleGroup: View {
    let enhancements: [PageEnhancement]
    @Bindable var model: EnhancementToggleModel
    var inPrompt = false
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(enhancements.enumerated()), id: \.element.id) { index, e in
                if index > 0 { Rectangle().fill(ColorTokens.line).frame(height: 0.5).padding(.leading, 56) }
                EnhancementToggleRow(enhancement: e, model: model, inPrompt: inPrompt)
            }
        }
        .background(PremiumCardSurface(radius: 12, elevated: false))
    }
}

private struct EnhancementToggleAtlas: ViewModifier {
    let enhancement: PageEnhancement
    let inPrompt: Bool
    func body(content: Content) -> some View {
        switch (enhancement, inPrompt) {
        case (.adSkip, false): content.atlas("control.settings.enhancementAdSkip")
        case (.sponsorSkip, false): content.atlas("control.settings.enhancementSponsorSkip")
        case (.adSkip, true): content.atlas("control.enhancement.promptAdSkip")
        case (.sponsorSkip, true): content.atlas("control.enhancement.promptSponsorSkip")
        }
    }
}

/// The one-time card over a service that declares page additions, the first time it is opened. A native card, never part of the page: the page
/// keeps loading underneath, nothing is on by default, and "Set up" leads to the same toggles and the same consent step as Settings.
struct EnhancementPromptCard: View {
    let enhancements: [PageEnhancement]
    @Bindable var model: EnhancementToggleModel
    var onDone: () -> Void
    @State private var settingUp = false

    /// The existing sentence, shown as a title and one calm line (split at the question mark; one title if it has none).
    private var parts: (title: String, detail: String) {
        let full = Localized.string("Skip ads and sponsor segments on YouTube? Both are off. You can change this any time in Settings.")
        guard let r = full.range(of: "? ") ?? full.range(of: "?") else { return (full, "") }
        return (String(full[..<r.upperBound]).trimmingCharacters(in: .whitespaces), String(full[r.upperBound...]).trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        let (title, detail) = parts
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                ServiceGlyph(id: .youtube, size: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Typography.heading).foregroundStyle(ColorTokens.textPrimary)
                        .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                    if !detail.isEmpty {
                        Text(detail).font(Typography.body).foregroundStyle(ColorTokens.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if settingUp { EnhancementToggleGroup(enhancements: enhancements, model: model, inPrompt: true) }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if settingUp {
                    Button("Done") { onDone() }.buttonStyle(PremiumButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction).atlas("control.enhancement.promptDone")
                } else {
                    Button("Not now") { onDone() }.buttonStyle(PremiumButtonStyle())
                        .keyboardShortcut(.cancelAction).atlas("control.enhancement.promptNotNow")
                    Button("Set up") { withAnimation(AnimationTokens.spring) { settingUp = true } }.buttonStyle(PremiumButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction).atlas("control.enhancement.promptSetUp")
                }
            }
        }
        .padding(16).frame(maxWidth: 440)
        .background(PremiumCardSurface())
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Page options".loc))
        .accessibilityIdentifier("enhancement.prompt")
        .enhancementConsentAlert(model)
    }
}
