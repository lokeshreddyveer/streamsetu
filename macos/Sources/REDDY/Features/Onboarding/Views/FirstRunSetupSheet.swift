import SwiftUI

extension Notification.Name {
    /// Opens the "Get set up" sheet again (Help menu).
    static let openFirstRunSetup = Notification.Name("app.openFirstRunSetup")
}

/// Offers the "Get set up" screen once, after the opening and the welcome screen are out of the way. The sheet configures what is not a playlist: Music, Podcasts and the
/// streaming services. Every answer is stored where the feature reads it (Podcasts: `PodcastPreferences`; services: the pinned list of the top bar; Music: its own first run).
struct FirstRunSetupHost: View {
    static let doneKey = "app.setup.done.v1"
    let services: ServiceNavigation
    let state: AppState
    /// True while the app is locked or in the Kids profile: nothing is offered then.
    let blocked: () -> Bool
    @State private var show = false

    var body: some View {
        // A full-window screen over the app (not a sheet): nothing of the screens behind it shows, and none of them can be clicked while it is up.
        ZStack {
            if show {
                FirstRunSetupSheet(openMusic: { services.selectMusic() }, done: { show = false })
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: show)
        .task(id: state.needsOnboarding) { await offerIfDue() }
        .onReceive(NotificationCenter.default.publisher(for: .openFirstRunSetup)) { _ in if !blocked() { show = true } }
    }

    private func offerIfDue() async {
        guard !UserDefaults.standard.bool(forKey: Self.doneKey), state.loaded, !state.needsOnboarding else { return }
        // After the opening has gone (it takes the whole window) and What's New, if it follows an update, has been dismissed: one screen at a time, never a sheet over another.
        let opening = OpeningCoordinator.shared
        for _ in 0..<600 where opening.isVisible || opening.showsWhatsNew { try? await Task.sleep(nanoseconds: 100_000_000) }
        try? await Task.sleep(nanoseconds: 600_000_000)
        guard !Task.isCancelled, !blocked(), !opening.showsWhatsNew, !UserDefaults.standard.bool(forKey: Self.doneKey) else { return }
        show = true
    }
}

/// "Get set up": three short steps (Music, Podcasts, streaming services), one thing to decide on each, with large tiles instead of a form. Nothing here is a playlist; every answer is stored
/// where the feature reads it, exactly as before, and "Not now" leaves everything as it was.
struct FirstRunSetupSheet: View {
    let openMusic: () -> Void
    let done: () -> Void
    /// False only for pictures made in tests (the offscreen renderer does not draw scroll views).
    private let scrolls: Bool

    private enum Step: Int, CaseIterable { case music, podcasts, services }

    @State private var step = Step.music
    @State private var forward = true
    @State private var setUpMusic = true
    @State private var region: String? = PodcastPreferences.region()
    @State private var genres: Set<PodcastGenre> = Set(PodcastPreferences.genres())
    @State private var pinned: Set<ProviderID> = Set(ServicePreferences.load().pinned)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(openMusic: @escaping () -> Void, done: @escaping () -> Void, initialStep: Int = 0, scrolls: Bool = true) {
        self.openMusic = openMusic; self.done = done; self.scrolls = scrolls
        _step = State(initialValue: Step(rawValue: initialStep) ?? .music)
    }

    private var providers: [ProviderDefinition] { ProviderRegistry.standard.listed(on: .macOS) }
    private var regions: [(code: String, name: String)] {
        Locale.Region.isoRegions.map(\.identifier).filter { $0.count == 2 && $0.allSatisfy(\.isLetter) }
            .compactMap { code in Locale.current.localizedString(forRegionCode: code).map { (code.lowercased(), $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private var accent: Color { ColorTokens.accent }
    private var isLast: Bool { step == .services }

    var body: some View {
        ZStack {
            // The whole window, in the saved theme: its background, with a soft wash of its accent at the top.
            ColorTokens.background.ignoresSafeArea()
            RadialGradient(colors: [accent.opacity(0.14), .clear], center: .top, startRadius: 0, endRadius: 420).ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ZStack {
                    content
                        .id(step)
                        .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                                                          removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                footer
            }
            .frame(maxWidth: 780)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityAddTraits(.isModal)
    }

    // MARK: header and footer

    private var header: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                SetupSymbol(accent: accent).frame(width: 30, height: 30).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Get set up").font(Typography.title).accessibilityAddTraits(.isHeader)
                    Text("Music, Podcasts and your streaming services need no playlist. Choose what you want here; you can change all of it later.")
                        .font(.callout).foregroundStyle(ColorTokens.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Capsule().fill(s.rawValue <= step.rawValue ? accent : ColorTokens.borderStrong)
                        .frame(width: s == step ? 34 : 10, height: 6)
                        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85), value: step)
                }
                Spacer()
                Text("\(step.rawValue + 1) of \(Step.allCases.count)").font(.caption.weight(.medium)).foregroundStyle(ColorTokens.textSecondary)
            }
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, 32).padding(.top, 26).padding(.bottom, 14)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Not now") { finish(save: false) }
                .buttonStyle(.plain).foregroundStyle(ColorTokens.textSecondary).keyboardShortcut(.cancelAction).atlas("control.setup.notNow")
            Spacer()
            if step != .music {
                Button("Back") { go(to: Step(rawValue: step.rawValue - 1) ?? .music) }
                    .buttonStyle(SetupButtonStyle(accent: accent, prominent: false)).atlas("control.setup.back")
            }
            if isLast {
                Button("Done") { finish(save: true); if setUpMusic { openMusic() } }
                    .buttonStyle(SetupButtonStyle(accent: accent, prominent: true)).keyboardShortcut(.defaultAction).atlas("control.setup.done")
            } else {
                Button("Continue") { go(to: Step(rawValue: step.rawValue + 1) ?? .services) }
                    .buttonStyle(SetupButtonStyle(accent: accent, prominent: true)).keyboardShortcut(.defaultAction).atlas("control.setup.next")
            }
        }
        .padding(.horizontal, 32).padding(.vertical, 18)
        .overlay(alignment: .top) { Rectangle().fill(ColorTokens.border).frame(height: 1) }
    }

    private func go(to next: Step) {
        forward = next.rawValue > step.rawValue
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .easeInOut(duration: 0.32)) { step = next }
    }

    // MARK: steps

    @ViewBuilder private var content: some View {
        switch step {
        case .music: musicStep
        case .podcasts: podcastsStep
        case .services: servicesStep
        }
    }

    private func stepHeading(_ title: LocalizedStringKey, _ symbol: String, _ subtitle: LocalizedStringKey) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(accent)
                .frame(width: 46, height: 46).background(Circle().fill(accent.opacity(0.16))).overlay(Circle().strokeBorder(accent.opacity(0.4), lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Typography.heading).accessibilityAddTraits(.isHeader)
                Text(subtitle).font(Typography.body).foregroundStyle(ColorTokens.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var musicStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeading("Music", "music.note", "Pick where Music finds songs, then tell it which languages, genres and artists you like.")
            VStack(spacing: 12) {
                Button { toggle { setUpMusic = true } } label: {
                    choiceLabel(selected: setUpMusic, symbol: "sparkles", title: "Set up Music when I finish", detail: "Opens Music's own setup: your sources, languages, genres and artists.")
                }
                .buttonStyle(.plain).accessibilityAddTraits(setUpMusic ? .isSelected : []).atlas("control.setup.music")
                Button { toggle { setUpMusic = false } } label: {
                    choiceLabel(selected: !setUpMusic, symbol: "clock", title: "I'll do it later", detail: "Start it any time from Music.")
                }
                .buttonStyle(.plain).accessibilityAddTraits(!setUpMusic ? .isSelected : []).atlas("control.setup.musicLater")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32).padding(.top, 8)
    }

    private var podcastsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeading("Podcasts", "mic.fill", "Charts follow the country you pick, and your categories become a row on Podcasts.")
            HStack(spacing: 10) {
                Text("Charts for").font(Typography.bodyMedium)
                Picker("Charts for", selection: $region) {
                    Text("My system's region").tag(String?.none)
                    ForEach(regions, id: \.code) { Text($0.name).tag(String?.some($0.code)) }
                }
                .labelsHidden().frame(maxWidth: 280).atlas("control.setup.podcastRegion")
                Spacer(minLength: 0)
            }
            Text("Categories you like").font(Typography.bodyMedium)
            maybeScroll {
                tileRows(PodcastGenre.allCases) { g in
                    let on = genres.contains(g)
                    Button { toggle { if on { genres.remove(g) } else { genres.insert(g) } } } label: {
                        tileLabel(selected: on) {
                            VStack(spacing: 7) {
                                Image(systemName: g.symbol).font(.system(size: 20, weight: .medium)).frame(height: 24)
                                Text(LocalizedStringKey(g.title)).font(.system(size: 12, weight: .semibold)).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.85)
                            }
                            .frame(maxWidth: .infinity, minHeight: 70)
                        }
                    }
                    .buttonStyle(.plain).accessibilityLabel(Text(LocalizedStringKey(g.title))).accessibilityAddTraits(on ? .isSelected : []).atlas("control.setup.podcastGenre")
                }
                .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 32).padding(.top, 8)
    }

    private var servicesStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeading("Streaming services", "play.rectangle.on.rectangle", "Pin the ones you use to the top bar. You sign in with your own account inside each service.")
            maybeScroll {
                tileRows(providers) { p in
                    let on = pinned.contains(p.id)
                    Button { toggle { if on { pinned.remove(p.id) } else { pinned.insert(p.id) } } } label: {
                        tileLabel(selected: on) {
                            VStack(spacing: 8) {
                                serviceIcon(p).frame(width: 38, height: 38)
                                Text(verbatim: p.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity, minHeight: 84)
                        }
                    }
                    .buttonStyle(.plain).accessibilityLabel(Text(verbatim: p.displayName)).accessibilityAddTraits(on ? .isSelected : []).atlas("control.setup.service")
                }
                .padding(.bottom, 4)
            }
            Group {
                if pinned.isEmpty { Text("None pinned yet") } else { Text("\(pinned.count) pinned") }
            }
            .font(.caption.weight(.medium)).foregroundStyle(ColorTokens.textSecondary)
        }
        .padding(.horizontal, 32).padding(.top, 8)
    }

    // MARK: pieces

    @ViewBuilder private func maybeScroll<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if scrolls { ScrollView { content() } } else { content() }
    }

    /// Items in rows of four, each cell the same width (a plain grid: about twenty tiles do not need lazy loading, and it lays out the same everywhere).
    private func tileRows<Item: Identifiable, Cell: View>(_ items: [Item], @ViewBuilder cell: @escaping (Item) -> Cell) -> some View {
        let rows = stride(from: 0, to: items.count, by: 4).map { Array(items[$0 ..< min($0 + 4, items.count)]) }
        return VStack(spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 10) {
                    ForEach(row) { cell($0) }
                    ForEach(0 ..< 4 - row.count, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }          // a filler for the last row, one point tall (a bare Color is as tall as it is offered)
                }
            }
        }
    }

    @ViewBuilder private func serviceIcon(_ p: ProviderDefinition) -> some View {
        if let image = ServiceIconStore.icon(for: p.id) {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit().clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        } else {
            Text(String(p.displayName.prefix(1))).font(.system(size: 18, weight: .bold)).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(ColorTokens.elevated))
        }
    }

    /// The look of a selectable tile: quiet when off; the accent in its fill, edge and a check when on. (The button around it sits at each call site, with its own Atlas id.)
    private func tileLabel<Content: View>(selected: Bool, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .foregroundStyle(selected ? ColorTokens.textPrimary : ColorTokens.textSecondary)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(selected ? accent.opacity(0.18) : ColorTokens.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(selected ? accent.opacity(0.85) : ColorTokens.border, lineWidth: selected ? 1.5 : 1))
            .overlay(alignment: .topTrailing) {
                if selected { Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(accent).background(Circle().fill(ColorTokens.background)).padding(6).transition(.scale.combined(with: .opacity)) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func toggle(_ change: () -> Void) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) { change() }
    }

    private func choiceLabel(selected: Bool, symbol: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(selected ? accent : ColorTokens.textSecondary).frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Typography.bodyMedium).foregroundStyle(ColorTokens.textPrimary)
                Text(detail).font(.callout).foregroundStyle(ColorTokens.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: selected ? "largecircle.fill.circle" : "circle").font(.system(size: 18)).foregroundStyle(selected ? accent : ColorTokens.borderStrong)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(selected ? accent.opacity(0.14) : ColorTokens.card))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(selected ? accent.opacity(0.85) : ColorTokens.border, lineWidth: selected ? 1.5 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func finish(save: Bool) {
        UserDefaults.standard.set(true, forKey: FirstRunSetupHost.doneKey)
        if save {
            PodcastPreferences.setRegion(region)
            PodcastPreferences.setGenres(PodcastGenre.allCases.filter(genres.contains))
            var prefs = ServicePreferences.load()
            for p in providers { if pinned.contains(p.id) { prefs.pin(p.id) } else if prefs.isPinned(p.id) { prefs.unpin(p.id) } }
            prefs.save()
            NotificationCenter.default.post(name: StreamingServicesSettingsModel.preferencesDidChange, object: nil)
            PodcastsHub.shared.loadTop(refresh: true)
        }
        done()
    }
}

/// The header's symbol (the two arcs and the rounded play triangle), drawn once at this small size in the accent.
private struct SetupSymbol: View {
    let accent: Color
    var body: some View {
        Canvas { ctx, size in
            let k = size.width / EclipseGeometry.canvas
            var c = ctx
            c.scaleBy(x: k, y: k)
            let line = StrokeStyle(lineWidth: EclipseGeometry.lineWidth, lineCap: .round)
            c.stroke(Path(EclipseGeometry.arc(EclipseGeometry.primary)), with: .color(accent), style: line)
            c.stroke(Path(EclipseGeometry.arc(EclipseGeometry.secondary)), with: .color(accent.opacity(EclipseGeometry.secondaryOpacity)), style: line)
            c.fill(Path(EclipseGeometry.play()), with: .color(accent))
        }
    }
}

private struct SetupButtonStyle: ButtonStyle {
    let accent: Color
    let prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(prominent ? (StartStyle.isLight(accent) ? ColorTokens.background : .white) : ColorTokens.textPrimary)
            .padding(.horizontal, 22).frame(minWidth: 96, minHeight: 36)
            .background(Capsule().fill(prominent ? accent : ColorTokens.elevated))
            .overlay(Capsule().strokeBorder(prominent ? accent.opacity(0.4) : ColorTokens.borderStrong))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .contentShape(Capsule())
    }
}
