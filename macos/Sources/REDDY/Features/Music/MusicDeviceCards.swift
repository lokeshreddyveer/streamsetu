import SwiftUI

// Building blocks shared by the Devices and Listen Together pages: the card surface, initial-based avatars, a compact device card, the
// current-output card, a "what to check" list and a two-column layout that stacks when it is narrow. No colour, font or radius of their own.

enum MusicDeviceMetrics {
    /// A card in the grid is never narrower than this, so name, chip and buttons keep their room.
    static let cardMinWidth: CGFloat = 300
    /// Two columns sit side by side only when each can be this wide.
    static let columnMinWidth: CGFloat = 320
    static let tile: CGFloat = MusicSpace.huge
}

extension View {
    /// The quiet card used on these pages: the elevated fill, a hairline, and the contrast border for Increase Contrast.
    func musicCardSurface(corner: CGFloat = MusicCorner.compactCardLarge) -> some View {
        background(ColorTokens.elevated, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(ColorTokens.line))
            .musicContrastBorder(cornerRadius: corner)
    }
}

// MARK: - Avatars

/// A round avatar drawn from a name: a stable gradient and one or two initials. Nothing is fetched. It is decoration; the name is always next to it.
struct MusicAvatar: View {
    let name: String
    var size: CGFloat = MusicTokens.avatarLarge

    var body: some View {
        ZStack {
            Circle().fill(MusicTokens.coverGradient(hue: MusicAvatarLogic.hue(name)))
            Text(verbatim: MusicAvatarLogic.initials(name))
                .font(size >= MusicSpace.huge ? MusicTypeRole.card.font : MusicTypeRole.caption.font).fontWeight(.semibold)
                .foregroundStyle(MusicInk.onArtwork).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// Overlapping avatars of the people in a room, with "+N" when there are more than fit.
struct MusicAvatarStack: View {
    let people: [MusicRoomPerson]
    var limit = 5
    var size: CGFloat = MusicTokens.avatarLarge

    var body: some View {
        HStack(spacing: -MusicSpace.xs) {
            ForEach(people.prefix(limit)) { p in
                MusicAvatar(name: p.name, size: size).overlay(Circle().strokeBorder(ColorTokens.elevated, lineWidth: 2))
            }
            if people.count > limit {
                Text(verbatim: "+\(people.count - limit)").musicText(.caption).foregroundStyle(ColorTokens.textSecondary)
                    .frame(width: size, height: size).background(ColorTokens.card, in: Circle())
                    .overlay(Circle().strokeBorder(ColorTokens.elevated, lineWidth: 2))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: people.map(\.name).joined(separator: ", ")))
    }
}

// MARK: - Device card

/// One device in a compact card: a kind icon, the name, one detail line, a state chip and the actions that make sense for that state.
struct MusicDeviceCard<Extra: View>: View {
    let kind: MusicDeviceKind
    let name: String
    let state: MusicDeviceCardState
    let detail: String
    var actions: [MusicDeviceCardState.Action]?
    /// The word on the forget button ("Forget" for a device this one controls, "Revoke" for one allowed to control this one).
    var forgetTitle = "Forget"
    let perform: (MusicDeviceCardState.Action) -> Void
    let extra: Extra
    @Environment(\.reddyAccent) private var accent

    init(kind: MusicDeviceKind, name: String, state: MusicDeviceCardState, detail: String, actions: [MusicDeviceCardState.Action]? = nil, forgetTitle: String = "Forget",
         perform: @escaping (MusicDeviceCardState.Action) -> Void, @ViewBuilder extra: () -> Extra) {
        self.kind = kind; self.name = name; self.state = state; self.detail = detail; self.actions = actions; self.forgetTitle = forgetTitle
        self.perform = perform; self.extra = extra()
    }

    private var shown: [MusicDeviceCardState.Action] { actions ?? state.actions }
    private var active: Bool { state == .thisDevice || state == .connected }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            HStack(spacing: MusicSpace.sm) {
                Image(systemName: kind.symbol).font(.system(size: MusicIconSize.row)).accessibilityHidden(true)
                    .foregroundStyle(active ? accent : ColorTokens.textSecondary)
                    .frame(width: MusicDeviceMetrics.tile, height: MusicDeviceMetrics.tile)
                    .background(active ? accent.opacity(MusicTokens.flashFill) : ColorTokens.card, in: Circle())
                VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                    Text(verbatim: name).musicText(.card).lineLimit(1).help(Text(verbatim: name))
                    Text(verbatim: detail).musicText(.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                MusicStatusChip(title: state.chip.title, symbol: state.chip.symbol, tone: state.chip.tone)
            }
            if !shown.isEmpty {
                HStack(spacing: MusicSpace.xs) {
                    ForEach(shown, id: \.self) { actionButton($0) }
                    Spacer(minLength: 0)
                }
            }
            extra
        }
        .padding(MusicSpace.sm)
        .musicCardSurface()
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func actionButton(_ a: MusicDeviceCardState.Action) -> some View {
        switch a {
        case .control:
            Button("Control") { perform(a) }.musicButton(.primary, size: .compact)
                .accessibilityLabel("Connect to \(name)").atlas("control.music.devicesConnectTo")
        case .pair:
            Button("Pair") { perform(a) }.musicButton(.secondary, size: .compact)
                .accessibilityLabel("Pair with \(name)").atlas("control.music.devicesPairWith")
        case .cancel:
            Button("Cancel") { perform(a) }.musicButton(.tertiary, size: .compact)
                .accessibilityLabel("Cancel pairing with \(name)").atlas("control.music.devicesCancel")
        case .disconnect:
            Button("Disconnect") { perform(a) }.musicButton(.secondary, size: .compact)
                .accessibilityLabel("Disconnect from \(name)").atlas("control.music.devicesDisconnect")
        case .forget:
            Button(forgetTitle.loc) { perform(a) }.musicButton(.tertiary, size: .compact)
                .accessibilityLabel("\(forgetTitle) \(name)").atlas("control.music.devicesMusicdevicespagepairedrowButton")
        }
    }
}

extension MusicDeviceCard where Extra == EmptyView {
    init(kind: MusicDeviceKind, name: String, state: MusicDeviceCardState, detail: String, actions: [MusicDeviceCardState.Action]? = nil, forgetTitle: String = "Forget",
         perform: @escaping (MusicDeviceCardState.Action) -> Void) {
        self.init(kind: kind, name: name, state: state, detail: detail, actions: actions, forgetTitle: forgetTitle, perform: perform, extra: { EmptyView() })
    }
}

enum MusicDeviceText {
    /// "Mac · Seen just now · Paired 3 Nov 2026": only facts the page really has.
    static func detail(_ e: MusicDeviceEntry) -> String {
        var parts = [Localized.string(e.kind.label)]
        switch e.lastSeen {
        case .now: parts.append(Localized.string("Seen just now"))
        case .notInThisSearch: parts.append(Localized.string("Did not answer this search"))
        case .notLookedYet: break
        }
        if let d = e.pairedAt { parts.append(Localized.string("Paired %@", d.formatted(date: .abbreviated, time: .omitted))) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Output card

/// Where Music plays now: the resolved output with the reason, and a way to change it (inline rows on the Mac, the system route picker on iPhone and iPad).
struct MusicOutputCard: View {
    let hub: MusicHub
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        #if os(macOS)
        let outputs = hub.player.outputs
        let attention = MusicOutputLine.needsAttention(outputs.resolution)
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            header(title: MusicOutputRoute.label(resolution: outputs.resolution, chosenName: outputs.chosenName),
                   detail: MusicOutputLine.detail(outputs.resolution, chosenName: outputs.chosenName), attention: attention)
            Divider().overlay(ColorTokens.line)
            outputRow(title: Localized.string("System default"), selected: outputs.chosenUID == nil) { outputs.choose(nil) }
            ForEach(outputs.available) { d in outputRow(title: d.name, selected: outputs.chosenUID == d.uid) { outputs.choose(d.uid) } }
            if let c = outputs.chosenUID, !outputs.available.contains(where: { $0.uid == c }) {
                HStack(spacing: MusicSpace.xs) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ColorTokens.warning).accessibilityHidden(true)
                    Text(verbatim: Localized.string("%@ (not connected)", outputs.chosenName ?? c)).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary)
                }
                .frame(minHeight: MusicTokens.hitTarget)
            }
        }
        .padding(MusicSpace.sm).musicCardSurface()
        .onAppear { outputs.start() }
        #else
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            HStack {
                header(title: Localized.string("Output device"), detail: Localized.string("Choose AirPlay, Bluetooth or the speaker for Music."), attention: false)
                MusicRoutePickerButton().frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget)
            }
        }
        .padding(MusicSpace.sm).musicCardSurface()
        #endif
    }

    private func header(title: String, detail: String, attention: Bool) -> some View {
        HStack(spacing: MusicSpace.sm) {
            MusicIcon(glyph: .devices, size: MusicIconSize.row, tint: .accent)
                .frame(width: MusicDeviceMetrics.tile, height: MusicDeviceMetrics.tile).background(accent.opacity(MusicTokens.flashFill), in: Circle())
            VStack(alignment: .leading, spacing: MusicSpace.xxs) {
                Text(verbatim: title).musicText(.card).lineLimit(1)
                Text(verbatim: detail).musicText(.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if attention { MusicStatusChip(title: "Using system output", symbol: "exclamationmark.triangle.fill", tone: .warning) }
            else { MusicStatusChip(title: "Playing here", symbol: "speaker.wave.2.fill", tone: .good) }
        }
    }

    #if os(macOS)
    private func outputRow(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: MusicSpace.xs) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? accent : ColorTokens.textTertiary).accessibilityHidden(true)
                Text(verbatim: title).musicText(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(minHeight: MusicTokens.hitTarget).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .atlas("control.music.playerBarOutputDevice")
    }
    #endif
}

// MARK: - Checklist and layout

/// "What to check": short lines with a mark, shown when a search finds nothing.
struct MusicCheckList: View {
    let title: String
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            Text(title.loc).musicText(.secondary).fontWeight(.semibold).foregroundStyle(ColorTokens.textSecondary)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: MusicSpace.xs) {
                    Image(systemName: "checkmark.circle").font(.system(size: MusicIconSize.small)).foregroundStyle(ColorTokens.textTertiary).accessibilityHidden(true)
                    Text(item.loc).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(MusicSpace.sm).frame(maxWidth: .infinity, alignment: .leading).musicCardSurface()
        .accessibilityElement(children: .combine)
    }
}

/// Two blocks side by side when each has room, stacked when not.
struct MusicAdaptivePair<A: View, B: View>: View {
    @ViewBuilder var first: A
    @ViewBuilder var second: B

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: MusicSpace.md) {
                first.frame(minWidth: MusicDeviceMetrics.columnMinWidth, maxWidth: .infinity, alignment: .topLeading)
                second.frame(minWidth: MusicDeviceMetrics.columnMinWidth, maxWidth: .infinity, alignment: .topLeading)
            }
            VStack(alignment: .leading, spacing: MusicSpace.md) { first; second }
        }
    }
}

/// The adaptive grid the device and participant cards sit in.
struct MusicDeviceCardGrid<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: MusicDeviceMetrics.cardMinWidth), spacing: MusicSpace.sm, alignment: .top)], alignment: .leading, spacing: MusicSpace.sm) { content }
    }
}
