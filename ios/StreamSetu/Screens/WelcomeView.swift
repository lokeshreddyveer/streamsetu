import SwiftUI

/// First launch: nothing is built in, so the screen is about adding what the person already has. One scrolling column on iPhone; on an
/// iPad (regular width) the symbol and the promise sit on the left and the ways to connect on the right.
struct OnboardingView: View {
    @Environment(IOSRouter.self) private var router
    @Environment(\.container) private var container
    @Environment(AppState.self) private var state
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The welcome comes before any theme choice, so it keeps the brand's own colours (the default palette).
    @Environment(\.startPalette) private var palette
    @State private var restore = ICloudRestore()
    @State private var pasted = ""
    /// Used only to read what the pasted text looks like; the sheet fills its own form from the same text.
    @State private var detector = AddSourceViewModel()

    /// Two columns only in a regular-width window at ordinary text sizes; the accessibility sizes get the one full-width column.
    private var twoColumns: Bool { sizeClass == .regular && !typeSize.isAccessibilitySize }
    private var recognised: Bool { SourceDetector.detect(pasted) != nil }

    var body: some View {
        Group {
            if twoColumns { wide } else { narrow }
        }
        .background(StartBackdrop(glowAt: twoColumns ? UnitPoint(x: 0.24, y: 0.4) : UnitPoint(x: 0.5, y: 0.14)))
        .onChange(of: pasted) { _, v in detector.paste(v) }.atlasScreen("screen.ios.welcome")
    }

    // MARK: Layouts

    private var narrow: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                FloatingBrandSymbol(size: 132)
                    .frame(maxWidth: .infinity)
                    .startRise(order: 0)
                promise(headline: 33).padding(.top, 18).startRise(order: 1)
                paste.padding(.top, 26).startRise(order: 2)
                chooseLabel.padding(.top, 28).padding(.bottom, 12).startRise(order: 3)
                StartTileGrid(pick: open)
                secondary.padding(.top, 24).startRise(order: 10)
                StartTrustRow(vertical: true).padding(.top, 28).startRise(order: 11)
                legal.padding(.top, 18).startRise(order: 11)
            }
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 32)
            .frame(maxWidth: 560).frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var wide: some View {
        GeometryReader { g in
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        FloatingBrandSymbol(size: 260)
                            .padding(.leading, -16)          // the symbol's picture has transparent margins; this lines its frame up with the text
                            .startRise(order: 0)
                        promise(headline: 46).padding(.top, 22).startRise(order: 1)
                        StartTrustRow(vertical: true).padding(.top, 32).startRise(order: 2)
                    }
                    .padding(.leading, 48).padding(.trailing, 24)
                    .frame(minHeight: g.size.height, alignment: .center)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: g.size.width * 0.45)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        paste.startRise(order: 2)
                        chooseLabel.padding(.top, 30).padding(.bottom, 12).startRise(order: 3)
                        StartTileGrid(columns: g.size.width * 0.55 > 760 ? 3 : 2, pick: open)
                        secondary.padding(.top, 24).startRise(order: 10)
                        legal.padding(.top, 18).startRise(order: 11)
                    }
                    .padding(.leading, 24).padding(.trailing, 48).padding(.vertical, 40)
                    .frame(maxWidth: 680, minHeight: g.size.height, alignment: .center)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
                .frame(width: g.size.width * 0.55)
            }
        }
    }

    // MARK: Parts

    private func promise(headline size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            StartLabel(text: "StreamSetu")
            Text("Your streams. One home.")
                .tracking(-0.6).appFont(size, .bold)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)          // already very large; past this it would push everything else off the screen
                .foregroundStyle(palette.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("Bring the playlists, logins and media servers you already have. StreamSetu keeps them together and plays them.")
                .appFont(16).foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460, alignment: .leading)
        }
    }

    private var paste: some View {
        StartPasteField(text: $pasted, note: pasted.isEmpty ? nil : detector.detectionNote, canSubmit: recognised) {
            router.addPreset = .pasted(pasted)
            router.presentAdd = true
        }
    }

    private var chooseLabel: some View {
        Text("Or choose how you connect").appFont(15, .semibold).foregroundStyle(palette.text)
            .accessibilityAddTraits(.isHeader)
    }

    private var secondary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { if let container { Task { await restore.start(container: container, state: state) } } } label: {
                HStack(spacing: 8) {
                    if restore.phase == .looking { ProgressView().tint(palette.text) }
                    Label("Restore from iCloud", systemImage: "icloud.and.arrow.down")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(StartSecondaryStyle()).disabled(restore.phase == .looking)
            .atlas("control.ios.welcome.restore")
            if restore.phase != .idle {
                Text(restore.detail).font(.footnote)
                    .foregroundStyle(restore.phase == .nothingFound ? ColorTokens.warning : palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var legal: some View {
        Text("StreamSetu is a player for services you are authorized to use.")
            .appFont(12).foregroundStyle(palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func open(_ tile: StartTile) {
        guard let kind = tile.kinds.first else { return }
        router.addPreset = .kind(kind)
        router.presentAdd = true
    }
}
