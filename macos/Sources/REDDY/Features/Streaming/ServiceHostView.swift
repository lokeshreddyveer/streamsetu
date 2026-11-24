import SwiftUI
import AppKit

/// Holds the model's web view. The container is what SwiftUI creates and removes; the web view itself is only moved in and out of it.
private final class WebContainer: NSView {
    func attach(_ web: NSView) {
        guard web.superview !== self else { return }
        subviews.forEach { $0.removeFromSuperview() }          // a web view made again after clearing replaces the old one
        web.removeFromSuperview()
        web.frame = bounds; web.autoresizingMask = [.width, .height]
        addSubview(web)
    }
}

private struct ServiceWebRepresentable: NSViewRepresentable {
    let model: ServiceWebModel
    var generation = 0          // read so SwiftUI updates the container when the model makes its web view again
    // Only an existing web view is attached here. The model makes it (when the service shows, or loads), never a view update: a view update
    // while the service's data is being cleared must not start a web process on that store.
    func makeNSView(context: Context) -> NSView { let c = WebContainer(); if let w = model.webView { c.attach(w) }; return c }
    func updateNSView(_ view: NSView, context: Context) { if let w = model.webView { (view as? WebContainer)?.attach(w) } }
    static func dismantleNSView(_ view: NSView, coordinator: ()) { view.subviews.forEach { $0.removeFromSuperview() } }
}

/// A service destination: the web view filling the content area, and StreamSetu's own states over it. No address bar, no tabs. Titles,
/// identifiers and strings come from the service's definition; the services differ only in configuration.
struct ServiceHostView: View {
    let model: ServiceWebModel
    /// Back to the app's own screens (the error screen of a service that never leaves the app offers it).
    var onReturn: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bannerDismissed = false
    @State private var showPrompt = false
    @State private var toggles = EnhancementToggleModel()

    private var name: String { model.definition.displayName }
    private var key: String { model.definition.id.rawValue }
    private var confirmsLinks: Bool { model.definition.externalLinks == .confirmThenOpen }

    /// A page that is still loading after about 20 s, with a page already showing: a slim bar above the page (it takes its own space, never covers the page).
    private var showsSlowBanner: Bool { model.isSlow && model.hasContent && !bannerDismissed }

    var body: some View {
        VStack(spacing: 0) {
            if showsSlowBanner { slowBanner.transition(.opacity) }
            if model.enhancementsStale { reloadBanner.transition(.opacity) }
            page
        }
        .onChange(of: model.phase) { _, p in if p != .loading { bannerDismissed = false } }
        .animation(reduceMotion ? nil : AnimationTokens.standard, value: showsSlowBanner)
        .sheet(item: Binding(get: { model.authPopup }, set: { if $0 == nil { model.closeAuthPopup() } })) { popup in
            AuthPopupSheet(popup: popup, serviceName: name) { model.closeAuthPopup() }
        }
    }

    /// A page addition was turned on or off after this page loaded: reloading applies it. Never reloads by itself.
    private var reloadBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise")
            Text(Localized.string("Reload %@ to apply your page options.", name)).font(Typography.caption)
            Spacer(minLength: 8)
            Button("Reload".loc) { model.applyEnhancementChanges() }.buttonStyle(.link).atlas("control.enhancement.reload")
        }
        .padding(.horizontal, 14).padding(.vertical, 6).frame(maxWidth: .infinity)
        .background(ColorTokens.elevated)
        .accessibilityElement(children: .contain).accessibilityIdentifier("\(key).reloadBanner")
    }

    private var slowBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock")
            Text((confirmsLinks ? "Still loading. If this doesn't finish, you can open it in your browser." : "Still loading. If this doesn't finish, try again.").loc).font(Typography.caption)
            Spacer(minLength: 8)
            if confirmsLinks { Button("Open in Default Browser".loc) { model.openInDefaultBrowser() }.buttonStyle(.link).atlas("control.service.openBrowser") }
            else { Button("Try Again".loc) { model.retry() }.buttonStyle(.link).atlas("control.service.retry") }
            Button("Dismiss".loc) { bannerDismissed = true }.buttonStyle(.link).atlas("control.service.dismissNotice")
        }
        .padding(.horizontal, 14).padding(.vertical, 6).frame(maxWidth: .infinity)
        .background(ColorTokens.elevated)
        .accessibilityElement(children: .contain).accessibilityIdentifier("\(key).slowBanner")
    }

    private var page: some View {
        ZStack {
            ColorTokens.contentBackground
            ServiceWebRepresentable(model: model, generation: model.state.webViewGeneration)
                .accessibilityLabel(name).accessibilityIdentifier("\(key).web")
            state
        }
        .overlay(alignment: .top) { notices }
        .overlay(alignment: .bottomTrailing) { pickButton }
        .overlay(alignment: .top) {
            if showPrompt {
                EnhancementPromptCard(enhancements: PageEnhancement.allCases.filter(model.definition.pageEnhancements.contains), model: toggles, providerID: model.definition.id) { showPrompt = false }
                    .padding(.top, 12).transition(reduceMotion ? .opacity : .scale(scale: 0.97, anchor: .top).combined(with: .opacity))
            }
        }
        .onAppear {
            // Once per service that declares page additions: recorded when shown, so it never comes back, whatever the answer.
            if !showPrompt, EnhancementRuntime.shared.shouldPrompt(for: model.definition) {
                EnhancementRuntime.shared.store.recordPromptAnswered(for: model.definition.id)
                withAnimation(reduceMotion ? AnimationTokens.quick : AnimationTokens.spring) { showPrompt = true }
            }
        }
        .animation(reduceMotion ? nil : AnimationTokens.standard, value: model.phase)
        .animation(reduceMotion ? nil : AnimationTokens.standard, value: model.notice)
        .animation(reduceMotion ? nil : AnimationTokens.standard, value: model.blockedLinkHost)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Open this link in your browser?".loc, isPresented: Binding(get: { confirmsLinks && model.pendingExternal != nil }, set: { if !$0 { model.cancelExternal() } })) {
            Button("Open".loc) { model.confirmExternal() }.atlas("control.service.openBlocked")
            Button("Cancel".loc, role: .cancel) { model.cancelExternal() }.atlas("control.service.dismissNotice")
        } message: {
            Text(verbatim: Localized.string("This page wants to open a link to %@ in your default browser.", model.pendingExternal.map(ServiceWebModel.destinationLabel) ?? ""))
        }
        .atlasScreen("screen.service.host")
    }

    @ViewBuilder private var state: some View {
        switch model.phase {
        case .loading where !model.hasContent:
            VStack(spacing: Spacing.md) {
                BrandLoader(size: 48, label: Localized.string("Opening %@…", name))
                if model.isSlow {
                    Text("This is taking longer than usual.").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                    if confirmsLinks { SecondaryButton(title: "Open in Default Browser", symbol: "safari") { model.openInDefaultBrowser() }.atlas("control.service.openBrowser") }
                    else { SecondaryButton(title: "Try Again", symbol: "arrow.clockwise") { model.retry() }.atlas("control.service.retry") }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(ColorTokens.contentBackground).transition(.opacity)
            .accessibilityElement(children: .contain).accessibilityIdentifier("\(key).loading")
        case .failed(let failure):
            if let screen = model.failureScreen {
                if case .regionRestricted = failure {
                    card(ServiceFailureCopy.text(for: failure, name: name, offersBrowser: false, officialSite: ServiceFailureCopy.officialSite(model.definition.homeURL)), actions: screen.actions, id: "\(key).regionRestricted",
                         details: ServiceFailureCopy.regionSeparation(name: name, profile: model.definition.regionProfile))
                } else { card(ServiceFailureCopy.text(for: failure, name: name, offersBrowser: confirmsLinks), actions: screen.actions, id: "\(key).error") }
            }
        case .terminated:
            if let screen = model.failureScreen { card(ServiceFailureCopy.terminated(name: name), actions: screen.actions, id: "\(key).terminated") }
        default:
            EmptyView()
        }
    }

    private func card(_ c: (symbol: String, title: String, message: String), actions: [ServiceFailureScreen.Action], id: String, details: [String] = []) -> some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: c.symbol).font(.system(size: 38)).foregroundStyle(ColorTokens.textSecondary)
            Text(c.title.loc).font(Typography.title)
            Text(c.message).font(Typography.body).foregroundStyle(ColorTokens.textSecondary).frame(maxWidth: 460).multilineTextAlignment(.center)
            if !details.isEmpty {
                VStack(alignment: .leading, spacing: 4) { ForEach(details, id: \.self) { Text(verbatim: $0) } }
                    .font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).frame(maxWidth: 460, alignment: .leading)
                    .accessibilityElement(children: .combine).accessibilityIdentifier("\(key).regionDetails")
            }
            HStack {
                ForEach(actions, id: \.self) { action in
                    switch action {
                    case .retry: PrimaryButton(title: "Try Again", symbol: "arrow.clockwise") { model.retry() }.atlas("control.service.retry")
                    case .openInDefaultBrowser: SecondaryButton(title: "Open in Default Browser", symbol: "safari") { model.openInDefaultBrowser() }.atlas("control.service.openBrowser")
                    case .returnToStreamSetu: SecondaryButton(title: "Return to StreamSetu", symbol: "house") { onReturn() }.atlas("control.service.returnHome")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(ColorTokens.contentBackground).transition(.opacity)
        .accessibilityElement(children: .contain).accessibilityIdentifier(id)
    }

    @ViewBuilder private var notices: some View {
        VStack(spacing: 6) {
            if model.notice != nil { pill("info.circle", Localized.string("Downloads aren't available in StreamSetu."), id: "\(key).notice") { model.dismissNotice() } }
            if model.state.hiddenUndo != nil {
                HStack(spacing: 10) {
                    Image(systemName: "eye.slash")
                    Text(Localized.string("Element hidden.")).font(Typography.caption)
                    Button("Undo".loc) { model.undoHideElement() }.buttonStyle(.link).atlas("control.service.undoHide")
                    Button("Dismiss".loc) { model.dismissPickerNotice() }.buttonStyle(.link).atlas("control.service.dismissNotice")
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule()).overlay(Capsule().strokeBorder(ColorTokens.glassEdge))
                .transition(.opacity).accessibilityElement(children: .contain).accessibilityIdentifier("\(key).hiddenUndo")
            }
            if let message = model.state.pickerMessage { pill("info.circle", Localized.string(message), id: "\(key).pickerMessage") { model.dismissPickerNotice() } }
            if let host = model.blockedLinkHost { pill("hand.raised", Localized.string("This link was blocked: %@. It is not an allowed sign-in or service address.", host), id: "\(key).blockedLink") { model.dismissBlockedLink() } }
        }
        .padding(.top, 10)
    }

    /// The second route to Hide Element, beside the page's right-click item: a small themed button that starts pick mode.
    @ViewBuilder private var pickButton: some View {
        if model.phase == .ready, TidyRules.supports(model.definition.id), model.pickRefusal == nil || model.state.picking {
            Button { model.startPickMode() } label: {
                Image(systemName: model.state.picking ? "xmark" : "eye.slash").font(.system(size: 12, weight: .semibold)).frame(width: 30, height: 30)
                    .foregroundStyle(model.state.picking ? ColorTokens.accentDefault : ColorTokens.textSecondary)
                    .background(.regularMaterial, in: Circle()).overlay(Circle().strokeBorder(ColorTokens.glassEdge))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain).padding(14)
            .help(model.state.picking ? Localized.string("Cancel") : Localized.string("Hide Element on This Page…"))
            .accessibilityLabel(Text(verbatim: Localized.string("Hide Element on This Page…"))).accessibilityIdentifier("\(key).hideElement")
            .atlas("control.service.hideElementButton")
        }
    }

    private func pill(_ symbol: String, _ text: String, id: String, dismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
            Text(text).font(Typography.caption)
            Button("Dismiss".loc, action: dismiss).buttonStyle(.link).atlas("control.service.dismissNotice")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule()).overlay(Capsule().strokeBorder(ColorTokens.glassEdge))
        .transition(.opacity)
        .accessibilityElement(children: .contain).accessibilityIdentifier(id)
    }
}

/// The native screen for a service whose registry entry is `disabled`: names the service and offers Return to StreamSetu only. No web view exists for it.
struct IntegrationUnavailableView: View {
    let definition: ProviderDefinition
    var onReturn: () -> Void = {}
    var body: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "nosign").font(.system(size: 38)).foregroundStyle(ColorTokens.textSecondary)
            Text(Localized.string("%@ isn't available", definition.displayName)).font(Typography.title)
            Text(Localized.string("%@ is not supported in this build of StreamSetu.", definition.displayName)).font(Typography.body)
                .foregroundStyle(ColorTokens.textSecondary).frame(maxWidth: 460).multilineTextAlignment(.center)
            SecondaryButton(title: "Return to StreamSetu", symbol: "house") { onReturn() }.atlas("control.service.returnHome")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(ColorTokens.contentBackground)
        .accessibilityElement(children: .contain).accessibilityIdentifier("\(definition.id.rawValue).unavailable")
        .atlasScreen("screen.service.unavailable")
    }
}

/// The sign-in window over a service: a small sheet with the page and a Close button. The page closes it itself when sign-in finishes.
private struct AuthPopupWebRepresentable: NSViewRepresentable {
    let popup: AuthPopup
    func makeNSView(context: Context) -> NSView { let c = WebContainer(); c.attach(popup.webView); return c }
    func updateNSView(_ view: NSView, context: Context) {}
    static func dismantleNSView(_ view: NSView, coordinator: ()) { view.subviews.forEach { $0.removeFromSuperview() } }
}

private struct AuthPopupSheet: View {
    let popup: AuthPopup
    let serviceName: String
    var close: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "lock").foregroundStyle(ColorTokens.textSecondary)
                Text(Localized.string("Sign in for %@", serviceName)).font(Typography.bodyMedium).foregroundStyle(ColorTokens.textPrimary)
                Spacer()
                Button("Close".loc) { close() }.keyboardShortcut(.cancelAction).atlas("control.service.authPopupClose")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(ColorTokens.elevated)
            AuthPopupWebRepresentable(popup: popup)
                .accessibilityLabel(Text(Localized.string("Sign in for %@", serviceName))).accessibilityIdentifier("service.authPopup.web")
        }
        .frame(width: 480, height: 640)
        .background(ColorTokens.contentBackground)
    }
}
