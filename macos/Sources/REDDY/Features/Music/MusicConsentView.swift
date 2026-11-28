import SwiftUI

/// First-run setup of what Music may talk to: one short card. The detailed per-source list opens only from "Choose sources myself".
/// Nothing is contacted until the person presses Continue, and everything can be changed later in Settings.
/// A first run starts from the default set (every built-in source but Local files); running setup again starts from what is on now.
struct MusicConsentView: View {
    let hub: MusicHub
    @State private var model: MusicSetupModel
    @State private var detailed = false
    @State private var sharedOpen = false
    @State private var groupOpen: Set<Int> = []
    @Environment(\.reddyAccent) private var accent

    init(hub: MusicHub) {
        self.hub = hub
        _model = State(initialValue: MusicSetupModel(providers: hub.registry.all, current: hub.registry.enabled))
    }

    private var providers: [any MusicProvider] { hub.registry.all }
    private var canContinue: Bool { model.canContinue }

    var body: some View {
        Group { if detailed { detailedBody } else { shortCard } }
            .atlasScreen("screen.music.setup")
    }

    // MARK: the short card

    private var sharedParagraph: String {
        let text = MusicSourceDisplay.sharedText(ids: model.enabling, providers: providers)
        return text.isEmpty ? Localized.string("Nothing is sent anywhere.") : text
    }

    private var shortCard: some View {
        VStack {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 12) {
                Text("Set up Music").font(Typography.title).accessibilityAddTraits(.isHeader)
                Text("Music searches and plays through online services.").font(Typography.body)
                Text("Search words, track titles and your IP address go to the services you use. No account is needed, and nothing is sent until you search or play.")
                    .font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup(isExpanded: $sharedOpen) {
                    ScrollView {
                        Text(verbatim: sharedParagraph).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 150).padding(.top, 4)
                } label: { Text("What is shared").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary) }
                    .atlas("control.music.setupShared")
                if !canContinue {
                    Text("Turn on at least one source to continue.").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                }
                HStack(spacing: 12) {
                    Button("Choose sources myself") { detailed = true }
                        .musicButton(.tertiary, accentText: true)
                        .atlas("control.music.setupCustomize")
                    Spacer(minLength: 8)
                    Button("Continue") { hub.completeConsent(enabling: model.enabling) }
                        .musicButton(.primary).disabled(!canContinue).atlas("control.music.setupContinue")
                }
            }
            .padding(22).frame(width: MusicTokens.setupCardWidth, alignment: .leading)
            .background(GlassBackground(radius: MusicTokens.radiusPanel))
            .clipShape(RoundedRectangle(cornerRadius: MusicTokens.radiusPanel, style: .continuous))
            .accessibilityElement(children: .contain)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.trailing, MusicTokens.assistantReserve)
    }

    // MARK: the detailed list

    private var detailedBody: some View {
        VStack(spacing: 0) {
            MusicPageColumn(spacing: MusicSpace.md) {
                    VStack(alignment: .leading, spacing: MusicSpace.xs) {
                        Text("Choose sources").font(Typography.pageTitle).accessibilityAddTraits(.isHeader)
                        Text("Nothing is contacted until you press Continue. Open Details on a source to see what it receives.")
                            .font(Typography.body).foregroundStyle(ColorTokens.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if providers.isEmpty {
                        MusicEmptyState(symbol: "music.note.list", title: Localized.string("No music sources are installed"), message: Localized.string("You can still use your local library."))
                    }
                    customList
            }
            footer
        }
    }

    // MARK: customize

    private var customList: some View {
        VStack(spacing: 10) {
            ForEach(MusicSetupGroup.allCases, id: \.rawValue) { g in
                let list = providers.filter { MusicSetupGroup.of($0) == g }
                if !list.isEmpty { groupSection(g, list) }
            }
        }
    }

    private func groupTitle(_ g: MusicSetupGroup) -> String {
        switch g { case .metadata: Localized.string("Search and browse"); case .audio: Localized.string("Audio"); case .lyrics: Localized.string("Lyrics"); case .scrobble: Localized.string("Scrobbling") }
    }

    private func groupSection(_ g: MusicSetupGroup, _ list: [any MusicProvider]) -> some View {
        let on = model.onCount(in: g)
        let recommended = model.recommended(in: g)
        let open = Binding<Bool>(get: { groupOpen.contains(g.rawValue) }, set: { if $0 { groupOpen.insert(g.rawValue) } else { groupOpen.remove(g.rawValue) } })
        return DisclosureGroup(isExpanded: open) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    if !recommended.isEmpty {
                        Button("Select recommended") { model.selectRecommended(in: g) }.musicButton(.secondary).atlas("control.music.setupGroupButtons")
                    }
                    Button("Turn all off") { model.turnOff(group: g) }.musicButton(.secondary).disabled(on == 0).atlas("control.music.setupGroupButtons")
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)
                ForEach(list, id: \.id) { p in
                    Divider()
                    SourceRow(info: p.info, isOn: Binding(get: { model.chosen.contains(p.id) }, set: { model.set(p.id, on: $0) }))
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Text(verbatim: groupTitle(g)).font(Typography.bodyMedium)
                Text(verbatim: Localized.string("%lld of %lld on", on, list.count)).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 2).background(ColorTokens.elevated, in: Capsule())
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
        .padding(14).surface(radius: MusicTokens.radiusCard)
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Back") { detailed = false }.musicButton(.tertiary, accentText: true).atlas("control.music.setupCustomize")
            Text(verbatim: canContinue ? "" : Localized.string("Turn on at least one source to continue."))
                .font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Continue") { hub.completeConsent(enabling: model.enabling) }
                .musicButton(.primary).disabled(!canContinue)
                .accessibilityHint(canContinue ? "" : Localized.string("Choose a source that finds music and one that plays it first"))
                .atlas("control.music.setupContinue")
        }
        .padding(.leading, 24).padding(.trailing, 24 + MusicTokens.assistantReserve).padding(.vertical, 12)
        .background(PodcastBarBackground())
    }
}

/// One source in Customize: name, one-line summary and the switch. What it receives and the unofficial note are behind Details.
private struct SourceRow: View {
    let info: MusicProviderInfo
    @Binding var isOn: Bool
    @State private var details = false
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: MusicSourceDisplay.name(for: info)).font(Typography.bodyMedium)
                        if MusicSourceDisplay.isUnofficial(info.id) {
                            Text("Unofficial").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                                .padding(.horizontal, 6).padding(.vertical, 1).overlay(Capsule().strokeBorder(ColorTokens.textTertiary))
                        }
                    }
                    Text(verbatim: info.summary).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
                }
            }
            .toggleStyle(.switch).tint(accent)
            .accessibilityLabel(MusicSourceDisplay.name(for: info)).atlas("control.music.setupSource")
            DisclosureGroup(isExpanded: $details) {
                VStack(alignment: .leading, spacing: 4) {
                    if !info.privacyNote.isEmpty { Text(verbatim: info.privacyNote) }
                    if MusicSourceDisplay.isUnofficial(info.id) { Text(verbatim: Localized.string(MusicLyricsSettingsLogic.unofficialNote)) }
                    if info.requiresSignIn { Text("Optional: connect your account later, from Plugins & sources. It does nothing until you do.") }
                }
                .font(Typography.caption).foregroundStyle(ColorTokens.textTertiary).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
            } label: { Text("Details").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary) }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }
}
