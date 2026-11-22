import SwiftUI

/// Where a title opens on the iPhone and iPad: set at the app's root to the detail page, so a link to another title works in every
/// navigation stack (Home, Library, Search, Favourites, a sheet …), not only in those that registered a destination for titles.
private struct TitleDestinationKey: EnvironmentKey { static let defaultValue: (@MainActor (LibraryItem) -> AnyView)? = nil }
extension EnvironmentValues {
    var titleDestination: (@MainActor (LibraryItem) -> AnyView)? { get { self[TitleDestinationKey.self] } set { self[TitleDestinationKey.self] = newValue } }
}

/// Opens a title's page from a row of titles on the iPhone and iPad. The row's buttons set `opened`; this pushes the page with the app's
/// title destination, inside whichever navigation stack the row is in. It is a plain push from the row itself, so it does not depend on
/// that stack having registered a destination for titles, and the row's chips can never swallow it. Nothing happens without a destination
/// (the Mac opens titles through its router instead).
struct OpensTitle: ViewModifier {
    @Binding var opened: LibraryItem?
    @Environment(\.titleDestination) private var destination

    func body(content: Content) -> some View {
        if let destination {
            content.navigationDestination(item: $opened) { item in destination(item) }
        } else {
            content
        }
    }
}

extension View {
    func opensTitle(_ opened: Binding<LibraryItem?>) -> some View { modifier(OpensTitle(opened: opened)) }
}

/// The open version in words under a title ("Hindi · Dubbed · FHD"), so two versions that look alike are never confused.
struct VersionPill: View {
    let item: LibraryItem
    var body: some View {
        if let text = OtherLanguages.versionLabel(title: item.title, folder: item.categoryName) {
            Label(text, systemImage: "character.bubble").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ColorTokens.textPrimary)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(.black.opacity(0.35)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
                .accessibilityLabel("Version: \(text)")
        }
    }
}

/// "Other languages" on a movie or series page: the same title in the other languages (and copies) the library holds, as a row of
/// chips of one fixed width, so nothing is ever cut off. The open version comes first, marked and not tappable; another opens that
/// version's page. Skeleton chips show while the versions are found (off the main thread, so the page never waits); the section is
/// hidden when there is no other version.
struct OtherLanguagesRow: View {
    let item: LibraryItem
    /// On the iPhone a chip is a navigation link, so Back returns here; on the Mac `onOpen` opens the version.
    var useLinks = false
    var onOpen: (LibraryItem) -> Void = { _ in }
    @Environment(\.container) private var container
    /// nil while the versions are being found.
    @State private var versions: [OtherLanguages.Version]?
    /// The version being opened on the iPhone and iPad.
    @State private var opened: LibraryItem?

    #if os(macOS)
    static let chipWidth: CGFloat = 200
    #else
    static let chipWidth: CGFloat = 176
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if versions == nil || (versions?.count ?? 0) > 1 {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Other languages").font(.system(size: 20, weight: .bold)).accessibilityAddTraits(.isHeader)
                        if let versions {
                            Text("\(versions.count) versions").font(.system(size: 12, weight: .semibold)).foregroundStyle(ColorTokens.textSecondary)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(ColorTokens.card))
                                .overlay(Capsule().strokeBorder(ColorTokens.border))
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            if let versions {
                                ForEach(versions) { v in chip(v) }
                            } else {
                                ForEach(0..<3, id: \.self) { _ in LanguageChipSkeleton(width: Self.chipWidth) }
                            }
                        }
                        .padding(.vertical, 8)
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .contentMargins(.horizontal, 20, for: .scrollContent)
                    .padding(.horizontal, -20)
                }
                .transition(.opacity)
            }
            // The loader sits on a view that is always there: a task on an empty view never runs.
            Color.clear.frame(height: 0).task(id: item.id) {
                // Found again when the page comes back into view, but the chips already shown stay in place meanwhile.
                if versions?.first?.item.id != item.id { versions = nil }
                guard let c = container else { versions = []; return }
                let service = OtherLanguagesService(catalog: c.catalog.recommendationView, preferredLanguage: c.settings.preferredAudioLanguage)
                let item = item
                let found = await Task.detached { service.versions(of: item) }.value
                if found != versions { withAnimation(.easeOut(duration: 0.25)) { versions = found } }
            }
        }
        .opensTitle($opened)
    }

    @ViewBuilder private func chip(_ v: OtherLanguages.Version) -> some View {
        if v.isCurrent {
            LanguageChip(version: v, width: Self.chipWidth)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(v.accessibilityLabel). The version you are on.")
        } else if useLinks {
            Button { opened = v.item } label: { LanguageChip(version: v, width: Self.chipWidth) }
                .buttonStyle(LanguageChipPress())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(v.accessibilityLabel). Opens this version.")
        } else {
            Button { onOpen(v.item) } label: { LanguageChip(version: v, width: Self.chipWidth) }
                .buttonStyle(LanguageChipPress())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(v.accessibilityLabel). Opens this version.")
        }
    }
}

/// One version: a small poster, the language on the first line, its own script, "Dubbed" or what tells it from another copy on the
/// second, and the picture quality as a badge in the corner. The open one is raised a little, with a check and an outline in the accent.
private struct LanguageChip: View {
    let version: OtherLanguages.Version
    let width: CGFloat
    #if os(macOS)
    @Environment(\.reddyAccent) private var accent
    #else
    private var accent: Color { .accentColor }
    #endif
    @State private var hovering = false

    var body: some View {
        let current = version.isCurrent
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ColorTokens.surface)
                if version.item.posterURL != nil {
                    ArtworkImage(url: version.item.posterURL, kind: .poster, contentMode: .fill, symbol: version.item.isSeries ? "tv" : "film")
                } else {
                    Image(systemName: version.item.isSeries ? "tv" : "film").foregroundStyle(ColorTokens.textTertiary)
                }
            }
            .frame(width: 44, height: 62)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(version.title).font(.system(size: 16, weight: .bold)).foregroundStyle(ColorTokens.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.8).truncationMode(.tail)
                if let caption = version.caption {
                    Text(caption).font(.system(size: 12)).foregroundStyle(ColorTokens.textSecondary).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 8).padding(.trailing, 10).padding(.vertical, 8)
        .frame(width: width, height: 78, alignment: .leading)
        .background(shape.fill(hovering && !current ? ColorTokens.elevated : ColorTokens.card))
        .overlay(shape.strokeBorder(current ? accent : (hovering ? ColorTokens.borderStrong : ColorTokens.border), lineWidth: current ? 2 : 1))
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 4) {
                if let badge = version.badge {
                    Text(badge).font(.system(size: 10, weight: .bold)).foregroundStyle(accent)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(accent.opacity(0.16)))
                }
                if current {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).foregroundStyle(.white, accent)
                }
            }
            .padding(6)
        }
        .shadow(color: .black.opacity(current ? 0.3 : (hovering ? 0.28 : 0)), radius: current ? 10 : 8, y: current ? 4 : 3)
        .offset(y: current ? -2 : (hovering ? -1 : 0))
        .contentShape(shape)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// A chip-shaped placeholder with a slow shimmer while the versions are found. Still with Reduce Motion.
private struct LanguageChipSkeleton: View {
    let width: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous).fill(ColorTokens.card)
            .overlay {
                GeometryReader { g in
                    LinearGradient(colors: [.clear, .white.opacity(0.07), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.6)
                        .offset(x: g.size.width * phase)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .frame(width: width, height: 78)
            .onAppear { if !reduceMotion { withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1.4 } } }
            .accessibilityHidden(true)
    }
}

/// Press feel: a little smaller and dimmer while held, springing back. With Reduce Motion it only dims.
private struct LanguageChipPress: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .animation(reduceMotion ? .linear(duration: 0.1) : .spring(response: 0.32, dampingFraction: 0.82), value: configuration.isPressed)
    }
}
