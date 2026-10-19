import SwiftUI

struct PageHead: View {
    let title: String
    var body: some View {
        Text(title.loc).font(.system(size: 23, weight: .semibold)).tracking(-0.6).accessibilityAddTraits(.isHeader)
    }
}

/// The one search field inside a tab. Header search and folder search are separate scopes.
struct InlineSearchField: View {
    @Binding var text: String
    let prompt: String
    var focusToken = 0
    @FocusState private var focused: Bool
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(ColorTokens.textTertiary)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(Typography.row).focused($focused).accessibilityLabel(prompt)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 12)) }
                    .buttonStyle(.plain).foregroundStyle(ColorTokens.textSecondary).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10).frame(height: 32)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(focused ? accent.opacity(0.55) : ColorTokens.glassEdge.opacity(0.8), lineWidth: focused ? 1.5 : 1))
        .onChange(of: focusToken) { _, _ in focused = true }
    }
}

/// Search, sort and count on one row, placed after the banner (or under the heading when there is none).
struct LibraryToolbar<Trailing: View>: View {
    @Binding var search: String
    let prompt: String
    let count: String
    var focusToken = 0
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            InlineSearchField(text: $search, prompt: prompt, focusToken: focusToken).frame(minWidth: 180, maxWidth: 450)
            Spacer(minLength: 8)
            trailing
            Text(count).font(Typography.caption).monospacedDigit().foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
        }
    }
}

struct SortMenu<Option: Hashable & Identifiable, Extra: View>: View {
    let options: [Option]
    @Binding var selection: Option
    var filterCount = 0
    let title: (Option) -> String
    @ViewBuilder var extra: Extra

    var body: some View {
        HStack(spacing: 8) {
            Text("SORT").font(Typography.eyebrow).tracking(1.4).foregroundStyle(ColorTokens.textSecondary)
            Menu {
                ForEach(options) { o in Button { selection = o } label: { Label(title(o), systemImage: o == selection ? "checkmark" : "") } }
                extra
            } label: { Text(filterCount > 0 ? "\(title(selection)) · \(filterCount) filter\(filterCount == 1 ? "" : "s")" : title(selection)).font(Typography.row) }
                .menuStyle(.button).menuIndicator(.visible).fixedSize()
        }
        .accessibilityElement(children: .combine).accessibilityLabel("Sort by \(title(selection))\(filterCount > 0 ? ", \(filterCount) filters on" : "")")
    }
}

extension SortMenu where Extra == EmptyView {
    init(options: [Option], selection: Binding<Option>, title: @escaping (Option) -> String) {
        self.init(options: options, selection: selection, filterCount: 0, title: title) { EmptyView() }
    }
}
