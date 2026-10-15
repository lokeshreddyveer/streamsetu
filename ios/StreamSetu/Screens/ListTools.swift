import SwiftUI

/// How a saved list (Favourites, Watch Later, a collection) is ordered.
enum TitleSort: String, CaseIterable, Identifiable {
    case recent = "Recently Added", az = "Title A–Z", za = "Title Z–A", newest = "Newest Year", rating = "Highest Rated"
    var id: String { rawValue }

    func apply(_ items: [LibraryItem]) -> [LibraryItem] {
        switch self {
        case .recent: items
        case .az: items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .za: items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedDescending }
        case .newest: items.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        case .rating: items.sorted { ($0.ratingValue ?? 0) > ($1.ratingValue ?? 0) }
        }
    }

    func apply(_ channels: [Channel]) -> [Channel] {
        switch self {
        case .recent, .newest, .rating: channels
        case .az: channels.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .za: channels.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        }
    }
}

extension View {
    /// A Sort menu and a Remove All button (with a confirmation) in the top bar of a saved list.
    func listTools(sort: Binding<TitleSort>?, canClear: Bool, clearLabel: String, confirmTitle: String, confirmMessage: String, onClear: @escaping () -> Void) -> some View {
        modifier(ListToolsModifier(sort: sort, canClear: canClear, clearLabel: clearLabel, confirmTitle: confirmTitle, confirmMessage: confirmMessage, onClear: onClear))
    }
}

private struct ListToolsModifier: ViewModifier {
    let sort: Binding<TitleSort>?
    let canClear: Bool
    let clearLabel: String
    let confirmTitle: String
    let confirmMessage: String
    let onClear: () -> Void
    @State private var confirming = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                TrailingPills {
                    if let sort {
                        Menu {
                            Picker("Sort", selection: sort) { ForEach(TitleSort.allCases) { Text($0.rawValue).tag($0) } }
                        } label: { Image(systemName: "arrow.up.arrow.down").pillIcon() }.accessibilityLabel("Sort")
                    }
                    Menu {
                        Button(clearLabel, systemImage: "trash", role: .destructive) { confirming = true }.disabled(!canClear)
                    } label: { Image(systemName: "ellipsis").pillIcon() }.accessibilityLabel("More")
                }
            }
            .confirmationDialog(confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
                Button(clearLabel, role: .destructive, action: onClear)
                Button("Cancel", role: .cancel) {}
            } message: { Text(confirmMessage) }
    }
}

/// Posters in a grid. Tap opens the title; hold for its menu; in Edit mode every poster has a red remove badge.
struct TitleGrid: View {
    let items: [LibraryItem]
    var editing = false
    var onRemove: (LibraryItem) -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var width: CGFloat { sizeClass == .regular ? 150 : 108 }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: width, maximum: width + 40), spacing: 14, alignment: .top)], spacing: 18) {
            ForEach(items) { t in
                ZStack(alignment: .topLeading) {
                    NavigationLink { DetailView(item: t) } label: { PosterCard(item: t, width: width) }.buttonStyle(.press)
                        .contextMenu { TitleMenu(item: t) }
                        .disabled(editing)
                    if editing {
                        Button { withAnimation(.snappy) { onRemove(t) } } label: {
                            Image(systemName: "minus.circle.fill").font(.system(size: 26)).symbolRenderingMode(.palette).foregroundStyle(.white, .red)
                                .shadow(radius: 3)
                        }.offset(x: -6, y: -8).accessibilityLabel("Remove \(t.title)")
                    }
                }
            }
        }
    }
}

/// Channels as small tiles with their logo. Tap plays; in Edit mode each has a red remove badge.
struct ChannelTileGrid: View {
    let channels: [Channel]
    var editing = false
    var onPlay: (Channel) -> Void
    var onRemove: (Channel) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92, maximum: 128), spacing: 10)], spacing: 10) {
            ForEach(channels) { c in
                ZStack(alignment: .topLeading) {
                    Button { onPlay(c) } label: {
                        VStack(spacing: 6) {
                            ChannelLogo(url: c.logoURL, name: c.name, size: 52)
                            Text(c.name).appFont(11, .medium).lineLimit(2).multilineTextAlignment(.center).frame(maxWidth: .infinity)
                        }
                        .padding(.vertical, 10).padding(.horizontal, 6).frame(maxWidth: .infinity, minHeight: 100)
                        .background(ColorTokens.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
                    }.buttonStyle(.press).disabled(editing)
                    if editing {
                        Button { withAnimation(.snappy) { onRemove(c) } } label: {
                            Image(systemName: "minus.circle.fill").font(.system(size: 24)).symbolRenderingMode(.palette).foregroundStyle(.white, .red).shadow(radius: 3)
                        }.offset(x: -5, y: -7).accessibilityLabel("Remove \(c.name)")
                    }
                }
            }
        }
    }
}

/// A section heading with a count, as on the Library screens.
struct ListHeader: View {
    let title: String
    let count: Int
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).appFont(20, .bold)
            Text("\(count)").appFont(14, .medium).foregroundStyle(.secondary)
            Spacer()
        }
    }
}

extension View {
    /// An Edit / Done button in the top bar.
    func editButton(_ editing: Binding<Bool>, enabled: Bool) -> some View {
        toolbar { TrailingPills { Button(editing.wrappedValue ? "Done" : "Edit") { withAnimation(.snappy) { editing.wrappedValue.toggle() } }.disabled(!enabled && !editing.wrappedValue) } }
    }
}
