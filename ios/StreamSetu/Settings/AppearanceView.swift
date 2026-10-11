import SwiftUI

/// Theme, accent colour and the custom theme editor.
struct AppearanceView: View {
    @Environment(AppSettings.self) private var settings
    @State private var draft = CustomTheme.standard

    var body: some View {
        @Bindable var s = settings
        Form {
            Section {
                ThemePreview(palette: s.theme == .custom ? draft.palette : s.theme.palette).frame(height: 120).listRowInsets(EdgeInsets())
            }.listRowBackground(ColorTokens.surface)
            Section {
                Toggle("Increase contrast", isOn: $s.highContrast)
            } footer: { Text("Brighter text and stronger outlines. Also follows Settings > Accessibility > Display > Increase Contrast.") }.listRowBackground(ColorTokens.surface)
            Section("Theme") {
                ForEach(AppTheme.Group.allCases, id: \.self) { group in
                    let themes = AppTheme.allCases.filter { $0.group == group }
                    if !themes.isEmpty {
                        DisclosureGroup(group.rawValue) {
                            ForEach(themes) { t in
                                Button { withAnimation { s.theme = t } } label: {
                                    HStack(spacing: 12) {
                                        Circle().fill(Color(hex: t.palette.background)).overlay(Circle().fill(Color(hex: t.palette.accent)).frame(width: 10, height: 10)).frame(width: 26, height: 26)
                                            .overlay(Circle().strokeBorder(.white.opacity(0.2)))
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(t.rawValue).foregroundStyle(.primary)
                                            Text(t.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer()
                                        if s.theme == t { Image(systemName: "checkmark").foregroundStyle(ColorTokens.accentDefault) }
                                    }
                                }
                            }
                        }
                    }
                }
            }.listRowBackground(ColorTokens.surface)
            if s.theme == .custom {
                Section("Custom theme") {
                    ColorPicker("Background", selection: binding(\.background), supportsOpacity: false)
                    ColorPicker("Accent", selection: binding(\.accent), supportsOpacity: false)
                    ColorPicker("Text", selection: binding(\.text), supportsOpacity: false)
                    VStack(alignment: .leading) {
                        Text("Gloss \(Int(draft.gloss * 100))%").font(.subheadline)
                        Slider(value: $draft.gloss, in: 0...1)
                    }
                    if !draft.isReadable {
                        Label(draft.textContrast < 4.5 ? "Text is hard to read on this background (contrast \(String(format: "%.1f", draft.textContrast)):1, aim for 4.5)." : "The accent is hard to see on this background.", systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    Button("Apply") { s.customTheme = draft }.disabled(draft == s.customTheme)
                    Button("Start Again", role: .destructive) { draft = .standard; s.customTheme = .standard }
                }.listRowBackground(ColorTokens.surface)
            }
            Section("Accent colour") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 10)], spacing: 10) {
                    ForEach(AccentChoice.allCases) { a in
                        Button { s.accent = a } label: {
                            Circle().fill(a.color).frame(width: 32, height: 32)
                                .overlay(Circle().strokeBorder(.white, lineWidth: s.accent == a ? 2.5 : 0).padding(-3))
                        }.buttonStyle(.press).accessibilityLabel(a.title).accessibilityAddTraits(s.accent == a ? .isSelected : [])
                    }
                }.padding(.vertical, 4)
            }.listRowBackground(ColorTokens.surface)
        }
        .navigationTitle("Appearance").themed("Appearance")
        .onAppear { draft = settings.customTheme }
    }

    private func binding(_ key: WritableKeyPath<CustomTheme, UInt32>) -> Binding<Color> {
        Binding(get: { Color(hex: draft[keyPath: key]) }, set: { draft[keyPath: key] = Self.hex($0) })
    }

    private static func hex(_ c: Color) -> UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
        func q(_ v: CGFloat) -> UInt32 { UInt32(min(255, max(0, (v * 255).rounded()))) }
        return q(r) << 16 | q(g) << 8 | q(b)
    }
}

/// A miniature of the app in the chosen colours.
private struct ThemePreview: View {
    let palette: ThemePalette
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(hex: palette.background)
            HStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    Color(hex: palette.panel)
                    VStack(alignment: .leading, spacing: 8) {
                        Capsule().fill(Color(hex: palette.accent)).frame(width: 34, height: 6)
                        Capsule().fill(Color(hex: palette.textTertiary).opacity(0.7)).frame(width: 40, height: 4)
                        Capsule().fill(Color(hex: palette.textTertiary).opacity(0.7)).frame(width: 30, height: 4)
                    }.padding(14)
                }.frame(width: 84)
                VStack(alignment: .leading, spacing: 10) {
                    Capsule().fill(Color(hex: palette.text)).frame(width: 90, height: 7)
                    HStack(spacing: 8) {
                        ForEach(0..<3, id: \.self) { _ in RoundedRectangle(cornerRadius: 6).fill(Color(hex: palette.card)).frame(height: 46) }
                    }
                    Capsule().fill(Color(hex: palette.accent)).frame(width: 60, height: 14)
                }.padding(14)
            }
            if palette.highlight > 0 { Rectangle().strokeBorder(LinearGradient(colors: [.white.opacity(palette.highlight), .clear], startPoint: .top, endPoint: .bottom)) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityHidden(true)
    }
}
