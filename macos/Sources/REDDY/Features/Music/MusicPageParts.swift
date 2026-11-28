import SwiftUI

// Flat page pieces for the small Music pages (Devices, Listen Together, Downloads, Import, Never Play): a titled section with quiet rows, a status
// chip, and a code card. They use the same type roles and spacing as the settings look, and no card sits behind a section.

/// A titled group: the title row (with an optional trailing control), a hairline, the rows, and one short footnote.
struct MusicPageSection<Trailing: View, Content: View>: View {
    let title: String
    var footnote: String?
    var trailing: Trailing
    var content: Content

    init(_ title: String, footnote: String? = nil, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title; self.footnote = footnote; self.trailing = trailing(); self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            HStack(alignment: .firstTextBaseline, spacing: MusicSpace.sm) {
                Text(title.loc).musicText(.section).accessibilityAddTraits(.isHeader)
                Spacer(minLength: MusicSpace.sm)
                trailing
            }
            Divider().overlay(ColorTokens.line)
            VStack(alignment: .leading, spacing: MusicSpace.sm) { content }
            if let footnote {
                Text(footnote.loc).musicText(.caption).foregroundStyle(ColorTokens.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension MusicPageSection where Trailing == EmptyView {
    init(_ title: String, footnote: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, footnote: footnote, trailing: { EmptyView() }, content: content)
    }
}


enum MusicStatusTone: Equatable, Sendable { case neutral, good, warning, bad }

/// A small status label that never rests on colour alone: it carries a symbol and a word.
struct MusicStatusChip: View {
    let title: String
    var symbol: String
    var tone: MusicStatusTone = .neutral

    private var color: Color {
        switch tone { case .neutral: ColorTokens.textSecondary; case .good: ColorTokens.success; case .warning: ColorTokens.warning; case .bad: ColorTokens.danger }
    }

    var body: some View {
        HStack(spacing: MusicSpace.xxs) {
            Image(systemName: symbol).font(.system(size: MusicIconSize.small, weight: .semibold)).accessibilityHidden(true)
            Text(title.loc).musicText(.caption)
        }
        .foregroundStyle(color)
        .padding(.horizontal, MusicSpace.xs).frame(minHeight: MusicSpace.xl)
        .background(ColorTokens.elevated, in: Capsule())
        .musicContrastBorder(cornerRadius: MusicSpace.xl)
        .accessibilityElement(children: .combine)
    }
}

/// A one-time code shown large, with the seconds it still works and a copy button. `onExpire` is called once the time is up.
struct MusicCodeCard: View {
    let code: String
    let expires: Date
    /// The line above the code ("Enter this code on the other device").
    let prompt: String
    /// The spoken label ("Pairing code 1 2 3 4 5 6") is `spokenPrefix` and the digits with spaces.
    let spokenPrefix: String
    /// The line under the code with a `%d` for the seconds left.
    let timeFormat: String
    let copyAtlas: String
    var onExpire: () -> Void = {}
    @State private var copied = false

    init(code: String, expires: Date, prompt: String, spokenPrefix: String, timeFormat: String, copyAtlas: String, onExpire: @escaping () -> Void = {}) {
        self.code = code; self.expires = expires; self.prompt = prompt; self.spokenPrefix = spokenPrefix
        self.timeFormat = timeFormat; self.copyAtlas = copyAtlas; self.onExpire = onExpire
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xs) {
            Text(prompt.loc).musicText(.secondary).foregroundStyle(ColorTokens.textSecondary)
            HStack(spacing: MusicSpace.md) {
                Text(verbatim: code).font(.system(size: MusicIconSize.hero, weight: .semibold, design: .monospaced)).tracking(MusicSpace.xxs)
                    .textSelection(.enabled).accessibilityLabel(Text(verbatim: spokenPrefix + " " + code.map(String.init).joined(separator: " ")))
                Spacer(minLength: MusicSpace.sm)
                MusicIconButton(systemImage: copied ? "checkmark" : "doc.on.doc", label: "Copy code", atlas: copyAtlas) { copy() }
            }
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let left = max(0, Int(expires.timeIntervalSince(ctx.date)))
                Text(verbatim: Localized.string(timeFormat, left)).musicText(.caption).foregroundStyle(ColorTokens.textTertiary)
                    .onChange(of: left == 0) { _, gone in if gone { onExpire() } }
            }
        }
        .padding(MusicSpace.md).frame(maxWidth: .infinity, alignment: .leading)
        .background(ColorTokens.elevated, in: RoundedRectangle(cornerRadius: MusicCorner.compactCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: MusicCorner.compactCard, style: .continuous).strokeBorder(ColorTokens.line))
        .musicContrastBorder(cornerRadius: MusicCorner.compactCard)
    }

    private func copy() {
        #if os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string)
        #else
        UIPasteboard.general.string = code
        #endif
        copied = true
        Task { try? await Task.sleep(for: .seconds(2)); copied = false }
    }
}
