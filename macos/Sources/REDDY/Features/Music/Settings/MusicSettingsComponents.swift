import SwiftUI

// The Music settings are built from the pieces below, which follow the measurements in MusicSettingsLayout: a group with its heading above its rows,
// rows with a label column and a control column, and a few one-line row kinds. A row is a short label on the left and its control on the right;
// longer words go in a popover or a group footer. The (i) sits after the label so every control lines up on the trailing edge.

extension MusicTokens {
    /// The one width of every menu, slider and button column on the other Music pages (the settings rows use `settingsRowControlWidth`).
    static let settingsControlWidth: CGFloat = 168
    static let settingsValueWidth: CGFloat = 52
    static let settingsFieldWidth: CGFloat = 220
    static let settingsStatusWidth: CGFloat = 92
    static let settingsPopoverWidth: CGFloat = 300
    /// The gap between groups, for blocks that hold several groups.
    static let settingsGroupSpacing: CGFloat = MusicSpace.xxl
}

/// A named group: the heading above its rows, an optional count line ("5 of 11 on") under it and an optional footer under the rows.
struct MusicSettingsGroup<Content: View>: View {
    let title: String
    var count: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSettingsLayout.headingGap) {
            Text(title.loc).musicScaledText(.section).foregroundStyle(ColorTokens.textPrimary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            if let count { Text(verbatim: count).musicScaledText(.caption).foregroundStyle(ColorTokens.textSecondary) }
            // The rows sit together on one quiet card, so a group reads as one thing and the page as a short list of cards (as in System Settings).
            VStack(alignment: .leading, spacing: MusicSettingsLayout.rowSpacing) { content }
                .padding(.horizontal, MusicSpace.md).padding(.vertical, MusicSpace.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ColorTokens.elevated.opacity(0.55), in: RoundedRectangle(cornerRadius: MusicTokens.radiusCard, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: MusicTokens.radiusCard, style: .continuous).strokeBorder(ColorTokens.line.opacity(0.6), lineWidth: 0.5))
            if let footer {
                Text(footer.loc).musicScaledText(.caption).foregroundStyle(ColorTokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: MusicTokens.noteMaxWidth, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum MusicSettingsCount {
    /// "5 of 11 on".
    static func text(_ on: Int, of total: Int) -> String { Localized.string("%d of %d on", on, total) }
}

/// A row: the label on the left with at most one short line under it, the control on the right. `info` adds a small (i) after the label that opens the
/// longer explanation. When the label column would be narrower than `MusicSettingsLayout.labelIdealWidth` (a narrow overlay or a large text step) the
/// control moves under the label, still on the trailing edge.
struct MusicSettingsRow<Control: View>: View {
    let title: String
    var atlas: String?
    var detail: String?
    var info: String?
    @ViewBuilder var control: Control

    private var label: some View {
        VStack(alignment: .leading, spacing: MusicSpace.xxs) {
            HStack(spacing: MusicSpace.xxs) {
                Text(title.loc).musicScaledText(.body).foregroundStyle(ColorTokens.textPrimary).fixedSize(horizontal: false, vertical: true).help(Text(title.loc))
                if let info { MusicInfoButton(title: title, text: info) }
            }
            if let detail {
                Text(detail.loc).musicScaledText(.caption).foregroundStyle(ColorTokens.textSecondary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true).help(Text(detail.loc))
            }
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: MusicSettingsLayout.labelGap) {
                label.frame(minWidth: 0, idealWidth: MusicSettingsLayout.labelIdealWidth, maxWidth: .infinity, alignment: .leading)
                control.labelsHidden().layoutPriority(1)
            }
            VStack(alignment: .leading, spacing: MusicSpace.xs) {
                label.frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 0) { Spacer(minLength: 0); control.labelsHidden() }
            }
        }
        .padding(.vertical, MusicSpace.xxs)
        .frame(minHeight: MusicSettingsLayout.rowHeight)
        .atlasOptional(atlas)
    }
}

struct MusicToggleRow: View {
    let title: String
    var atlas: String?
    var detail: String?
    var info: String?
    @Binding var isOn: Bool

    var body: some View {
        MusicSettingsRow(title: title, atlas: atlas, detail: detail, info: info) {
            Toggle(title.loc, isOn: $isOn).toggleStyle(.switch).padding(.leading, MusicSettingsLayout.toggleGap)
        }
    }
}

struct MusicPickerRow<Value: Hashable>: View {
    let title: String
    var atlas: String?
    var detail: String?
    var info: String?
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    private var current: String { options.first { $0.value == selection }?.label ?? "" }

    var body: some View {
        MusicSettingsRow(title: title, atlas: atlas, detail: detail, info: info) {
            Picker(title.loc, selection: $selection) { ForEach(options, id: \.value) { Text($0.label.loc).tag($0.value) } }
                .pickerStyle(.menu).frame(width: MusicSettingsLayout.controlWidth, alignment: .trailing).help(Text(current.loc))
        }
    }
}

struct MusicSliderRow: View {
    let title: String
    var atlas: String?
    var detail: String?
    var info: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    let valueText: String

    var body: some View {
        MusicSettingsRow(title: title, atlas: atlas, detail: detail, info: info) {
            HStack(spacing: MusicSpace.xs) {
                Slider(value: $value, in: range, step: step).frame(width: MusicSettingsLayout.controlWidth - MusicSettingsLayout.valueWidth - MusicSpace.xs)
                Text(verbatim: valueText).musicScaledText(.caption).monospacedDigit().foregroundStyle(ColorTokens.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.8).frame(width: MusicSettingsLayout.valueWidth, alignment: .trailing).help(Text(verbatim: valueText))
            }
            .frame(width: MusicSettingsLayout.controlWidth, alignment: .trailing)
        }
    }
}

/// A row whose control is one button: the Music secondary button everywhere.
struct MusicButtonRow: View {
    let title: String
    var atlas: String?
    var detail: String?
    var info: String?
    let button: String
    var role: ButtonRole?
    var disabled = false
    let action: () -> Void

    var body: some View {
        MusicSettingsRow(title: title, atlas: atlas, detail: detail, info: info) {
            Button(button.loc, role: role, action: action).musicButton(role == .destructive ? .destructive : .secondary).disabled(disabled)
        }
    }
}

/// A row with a text field (or a secret field) in the control column.
struct MusicFieldRow: View {
    let title: String
    var atlas: String?
    var detail: String?
    var info: String?
    var prompt: String = ""
    var secret = false
    @Binding var text: String

    var body: some View {
        MusicSettingsRow(title: title, atlas: atlas, detail: detail, info: info) {
            Group {
                if secret { SecureField(title.loc, text: $text, prompt: Text(prompt.loc)) } else { TextField(title.loc, text: $text, prompt: Text(prompt.loc)) }
            }
            .textFieldStyle(.roundedBorder).frame(width: MusicSettingsLayout.controlWidth).help(text.isEmpty ? Text(title.loc) : Text(verbatim: text))
        }
    }
}

/// A read-only line: the label on the left, the value on the trailing edge (two lines at most, cut in the middle, the full value in the tooltip).
struct MusicValueRow: View {
    let title: String
    let value: String
    var tone: SettingsValueRow.Tone = .normal
    var divider = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: MusicSettingsLayout.labelGap) {
            Text(title.loc).musicScaledText(.body).foregroundStyle(ColorTokens.textPrimary).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(value).musicScaledText(.body).monospacedDigit().foregroundStyle(MusicNoteTone.color(tone)).multilineTextAlignment(.trailing)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled).help(Text(verbatim: value))
        }
        .padding(.vertical, MusicSpace.xxs)
        .frame(minHeight: MusicSettingsLayout.compactRowHeight)
    }
}

/// A row of actions at the bottom of a group: Music buttons in one line when they fit, one above the other when they do not.
struct MusicSettingsActions<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: MusicSpace.xs) { content; Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: MusicSpace.xs) { content }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.music())
        .focusEffectDisabled()
    }
}

/// Settings most people never change, folded under one line. The header is a button with a chevron and a spoken state, so it works from the keyboard.
struct MusicSettingsDisclosure<Content: View>: View {
    let title: String
    var footer: String?
    @State private var open = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSettingsLayout.rowSpacing) {
            Button {
                if BrandMotion.reduced(systemReduceMotion) { open.toggle() } else { withAnimation(MusicTokens.standard) { open.toggle() } }
            } label: {
                HStack(spacing: MusicSpace.xs) {
                    Image(systemName: "chevron.right").font(MusicTokens.iconSmall).foregroundStyle(ColorTokens.textSecondary)
                        .rotationEffect(.degrees(open ? 90 : 0)).frame(width: MusicSpace.md).accessibilityHidden(true)
                    Text(title.loc).musicScaledText(.card).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: MusicSettingsLayout.compactRowHeight, alignment: .leading)
            }
            .buttonStyle(MusicDisclosureStyle())
            .accessibilityLabel(Text(title.loc)).accessibilityValue((open ? Text("Expanded") : Text("Collapsed")))
            .atlas("control.music.settingsDisclosure")
            if open {
                VStack(alignment: .leading, spacing: MusicSettingsLayout.rowSpacing) { content }
                    .padding(.leading, MusicSpace.md)
                if let footer {
                    Text(footer.loc).musicScaledText(.caption).foregroundStyle(ColorTokens.textSecondary)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: MusicTokens.noteMaxWidth, alignment: .leading)
                }
            }
        }
    }
}

/// A plain secondary line inside a group, for an empty list or a short result.
struct MusicNote: View {
    let text: String
    var tone: SettingsValueRow.Tone = .normal
    var body: some View {
        Text(text.loc).musicScaledText(.caption).foregroundStyle(MusicNoteTone.color(tone)).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: MusicTokens.noteMaxWidth, alignment: .leading)
    }
}

// MARK: popovers

/// What a details popover shows: an optional title and the longer words, in the small secondary type.
struct MusicDetailsPopover<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: MusicSpace.sm) {
            if let title { Text(title.loc).font(Typography.bodyMedium) }
            content.font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(MusicSpace.md).frame(width: MusicTokens.settingsPopoverWidth, alignment: .leading)
    }
}

/// The small (i) after a row's label. It opens the longer explanation; nothing is shown under the row.
struct MusicInfoButton: View {
    var title: String?
    let text: String
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle").foregroundStyle(ColorTokens.textTertiary)
                .frame(width: MusicHitTarget.minimum, height: MusicHitTarget.minimum).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("More information")).accessibilityHint(Text(text.loc))
        .help(Text("More information"))
        .popover(isPresented: $shown, arrowEdge: .bottom) { MusicDetailsPopover(title: title) { Text(text.loc) } }.atlas("control.music.settingsMoreInformation")
    }
}

// MARK: source rows

/// The one-word state of a source in a table.
enum MusicSourceStatus: Equatable, Sendable {
    case on, off, needsSignIn, unreachable, attention
    /// A short fact in the status column that is not a state, such as "12 tracks".
    case note(String)

    var title: String {
        switch self {
        case .on: "On"; case .off: "Off"; case .needsSignIn: "Needs sign-in"; case .unreachable: "Unreachable"; case .attention: "Check settings"
        case .note(let text): text
        }
    }
    var tone: SettingsValueRow.Tone {
        switch self { case .on, .off, .note: .normal; case .needsSignIn, .unreachable: .warning; case .attention: .bad }
    }
}

/// How a row takes part in an order table: it carries its own id, accepts another row dropped on it, and can step one place for keyboard use.
struct MusicReorder {
    let id: String
    let drop: (_ dragged: String) -> Void
    let step: (_ delta: Int) -> Void
}

/// One line of a compact table: name, one-word status, switch. What is sent, who runs it and the rest sit in the Details popover.
/// Only an order table shows the grip, and only it can be dragged.
struct MusicSourceRow<Detail: View>: View {
    let name: String
    var version: String?
    /// Small neutral labels under the name: the kind (Built-in, Plugin) and what the source does.
    var tags: [String] = []
    let status: MusicSourceStatus
    var isOn: Binding<Bool>?
    var reorder: MusicReorder?
    var first = false
    var hasDetail = true
    @ViewBuilder var detail: Detail
    @State private var shown = false

    var body: some View {
        VStack(spacing: 0) {
            if !first { Divider().overlay(ColorTokens.line) }
            HStack(spacing: Spacing.sm) {
                if reorder != nil {
                    Image(systemName: "line.3.horizontal").foregroundStyle(ColorTokens.textTertiary).frame(width: Spacing.lg).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    HStack(spacing: Spacing.xs) {
                        Text(verbatim: name).lineLimit(1).help(Text(verbatim: name))
                        if let version { Text(verbatim: version).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary) }
                    }
                    if !tags.isEmpty {
                        HStack(spacing: Spacing.xs) {
                            ForEach(tags, id: \.self) { tag in
                                Text(tag.loc).font(Typography.micro).foregroundStyle(ColorTokens.textSecondary)
                                    .padding(.horizontal, Spacing.sm - Spacing.xxs).padding(.vertical, Spacing.xxs)
                                    .background(ColorTokens.elevated, in: Capsule())
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                .onTapGesture { if hasDetail { shown = true } }.atlas("control.music.settingsMusicsourcerowbodyOnTapGesture")
                Text(status.title.loc).font(Typography.caption).foregroundStyle(MusicNoteTone.color(status.tone)).lineLimit(1).minimumScaleFactor(0.8).help(Text(status.title.loc))
                    .frame(width: MusicTokens.settingsStatusWidth, alignment: .trailing)
                if hasDetail {
                    Button("Details") { shown = true }.musicButton(.tertiary, size: .compact)
                        .accessibilityLabel(Text(verbatim: Localized.string("Details for %@", name)))
                        .popover(isPresented: $shown, arrowEdge: .bottom) { MusicDetailsPopover(title: name) { detail } }.atlas("control.music.settingsDetails")
                }
                if let isOn { Toggle(name, isOn: isOn).toggleStyle(.switch).labelsHidden().atlas("control.music.settingsMusicsourcerowbodyToggle") }
            }
            .padding(.vertical, MusicSpace.xxs).frame(minHeight: MusicSettingsLayout.rowHeight)
            .accessibilityElement(children: .contain)
            .modifier(MusicReorderModifier(name: name, reorder: reorder))
        }
    }
}

private enum MusicNoteTone {
    static func color(_ t: SettingsValueRow.Tone) -> Color {
        switch t { case .normal: ColorTokens.textSecondary; case .good: ColorTokens.success; case .warning: ColorTokens.warning; case .bad: ColorTokens.danger }
    }
}

private struct MusicReorderModifier: ViewModifier {
    let name: String
    let reorder: MusicReorder?

    func body(content: Content) -> some View {
        if let r = reorder {
            content
                .draggable(r.id) { Text(verbatim: name).padding(Spacing.sm) }
                .dropDestination(for: String.self) { items, _ in
                    guard let dragged = items.first, dragged != r.id else { return false }
                    r.drop(dragged)
                    return true
                }
                .contextMenu {
                    Button("Move up") { r.step(-1) }.atlas("control.music.settingsMoveUp")
                    Button("Move down") { r.step(1) }.atlas("control.music.settingsMoveDown")
                }
                .accessibilityAction(named: Text("Move up")) { r.step(-1) }
                .accessibilityAction(named: Text("Move down")) { r.step(1) }.atlas("control.music.settingsMoveUp")
        } else {
            content
        }
    }
}

/// The ordering rules shared by every order table.
enum MusicOrderLogic {
    /// Moves `id` one step (`delta` -1 up, +1 down) and returns the new order; unchanged at the ends or for an unknown id.
    static func moved(_ ids: [String], id: String, by delta: Int) -> [String] {
        guard let i = ids.firstIndex(of: id) else { return ids }
        let j = i + delta
        guard ids.indices.contains(j) else { return ids }
        var out = ids; out.swapAt(i, j); return out
    }

    /// Puts `dragged` where `target` is; unchanged when either is unknown.
    static func dropped(_ ids: [String], dragged: String, onto target: String) -> [String] {
        guard let from = ids.firstIndex(of: dragged), let to = ids.firstIndex(of: target), from != to else { return ids }
        var out = ids
        let item = out.remove(at: from)
        out.insert(item, at: to)
        return out
    }
}
