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

    private var name: String { model.definition.displayName }
    private var key: String { model.definition.id.rawValue }
    private var confirmsLinks: Bool { model.definition.externalLinks == .confirmThenOpen }

    /// A page that is still loading after about 20 s, with a page already showing: a slim bar above the page (it takes its own space, never covers the page).
    private var showsSlowBanner: Bool { model.isSlow && model.hasContent && !bannerDismissed }

    var body: some View {
        VStack(spacing: 0) {
            if showsSlowBanner { slowBanner.transition(.opacity) }
            page
        }
        .onChange(of: model.phase) { _, p in if p != .loading { bannerDismissed = false } }
        .animation(reduceMotion ? nil : AnimationTokens.standard, value: showsSlowBanner)
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
            if let screen = model.failureScreen { card(ServiceFailureCopy.text(for: failure, name: name, offersBrowser: confirmsLinks), actions: screen.actions, id: "\(key).error") }
        case .terminated:
            if let screen = model.failureScreen { card(ServiceFailureCopy.terminated(name: name), actions: screen.actions, id: "\(key).terminated") }
        default:
            EmptyView()
        }
    }

    private func card(_ c: (symbol: String, title: String, message: String), actions: [ServiceFailureScreen.Action], id: String) -> some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: c.symbol).font(.system(size: 38)).foregroundStyle(ColorTokens.textSecondary)
            Text(c.title.loc).font(Typography.title)
            Text(c.message).font(Typography.body).foregroundStyle(ColorTokens.textSecondary).frame(maxWidth: 460).multilineTextAlignment(.center)
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
            if let host = model.blockedLinkHost { pill("hand.raised", Localized.string("Link blocked: %@", host), id: "\(key).blockedLink") { model.dismissBlockedLink() } }
        }
        .padding(.top, 10)
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
