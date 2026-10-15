import SwiftUI

/// One page of settings, set out like Safari's: each group's name in a column on the left, its rows in a column on the right.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) { content }
                .padding(.horizontal, 26).padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A named group: the name on the left, the rows on the right with the footer under them.
struct SettingsGroup<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            Text(title.loc).font(.system(size: 13, weight: .semibold)).multilineTextAlignment(.trailing)
                .frame(width: 130, alignment: .trailing)
            VStack(alignment: .leading, spacing: 14) {
                content
                if let footer {
                    Text(footer.loc).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One row: the label and its explanation on the left, the control on the right. `note` explains why a control is unavailable.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    var note: String?
    var divider = true
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title.loc)
                if let detail { Text(detail.loc).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if let note { Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control.labelsHidden().layoutPriority(1)
        }
    }
}

/// Read-only value row (counts, dates, status).
struct SettingsValueRow: View {
    let title: String
    let value: String
    var tone: Tone = .normal
    var divider = true
    enum Tone { case normal, good, warning, bad }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title.loc).frame(maxWidth: .infinity, alignment: .leading)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing).foregroundStyle(color).textSelection(.enabled)
        }
    }
    private var color: Color { switch tone { case .normal: .secondary; case .good: ColorTokens.success; case .warning: ColorTokens.warning; case .bad: ColorTokens.danger } }
}

/// Feedback shown after an action. Persists until the next action so it can be read.
struct SettingsMessage: Equatable {
    enum Kind { case success, failure, info }
    var text: String
    var kind: Kind = .success
}

struct MessageLine: View {
    let message: SettingsMessage?
    var body: some View {
        if let m = message {
            Label(m.text, systemImage: m.kind == .success ? "checkmark.circle.fill" : m.kind == .failure ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.callout).foregroundStyle(m.kind == .success ? ColorTokens.success : m.kind == .failure ? ColorTokens.warning : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
        }
    }
}

/// Button for work that takes time. It shows a spinner and ignores further clicks until the work finishes, so an operation
/// can never be started twice, and the rest of the window stays usable.
struct AsyncActionButton: View {
    let title: String
    var symbol: String?
    var role: ButtonRole?
    var busyTitle: String?
    let action: () async -> Void
    @State private var running = false

    var body: some View {
        Button(role: role) {
            guard !running else { return }
            running = true
            Task { await action(); running = false }
        } label: {
            HStack(spacing: 6) {
                if running { ProgressView().controlSize(.small) } else if let symbol { Image(systemName: symbol) }
                Text(running ? (busyTitle ?? title) : title)
            }
        }
        .disabled(running)
        .accessibilityLabel(title)
    }
}

/// A row of actions at the bottom of a group.
struct SettingsActions<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 8) { content; Spacer(minLength: 0) }
            .buttonStyle(.bordered)
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true) }
}

struct CapabilityChip: View {
    let title: String
    let on: Bool
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: on ? "checkmark" : "minus").font(.system(size: 8, weight: .bold))
            Text(title.loc).font(Typography.caption)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .foregroundStyle(on ? ColorTokens.textPrimary : ColorTokens.textTertiary)
        .background(Color.white.opacity(on ? 0.08 : 0.03), in: Capsule())
        .accessibilityElement(children: .combine).accessibilityLabel("\(title): \(on ? "supported" : "not supported")")
    }
}


/// A group whose rows stay folded until asked for, for settings most people never change. The header is a plain button, so a
/// click anywhere on it opens or closes the group.
struct SettingsDisclosure<Content: View>: View {
    let title: String
    var footer: String?
    @State private var open = false
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            Color.clear.frame(width: 130, height: 1)
            VStack(alignment: .leading, spacing: 14) {
                Button { withAnimation(AnimationTokens.standard) { open.toggle() } } label: {
                    HStack {
                        Text(title.loc).font(.headline)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title).accessibilityValue(open ? "expanded" : "collapsed").accessibilityAddTraits(.isButton)
                if open {
                    content
                    if let footer { Text(footer.loc).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
