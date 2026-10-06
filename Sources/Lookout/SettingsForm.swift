import SwiftUI

// The pieces of a settings form (DESIGN.md 5.8), shared by the Settings panes and the Repositories page.
//
//   FormGroup   An optional `label` title (20 above, 6 below) over one inset `Fill.group` radius-10 group. Rows go
//               in it with a `FormDivider` between them: hairlines are placed by hand, so a row that comes and goes
//               takes its own divider along.
//   FormRow     Label left, control right, at least 36 tall; `detail` only where it prevents a mistake.
//   FormToggle  A row whose whole width is the drawn switch (`SwitchStyle`).
//   PopUp       A bordered pop-up button with plain words, for a choice of a few.
//   SecretField A `SecureField` that Return saves and Esc leaves, for a token or a key.
//   RemovableTag  A capsule with a 24pt remove button (bot handles, muted folders).

struct FormGroup<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content
    @Environment(\.resolved) private var resolved

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if let title {
                Text(title).font(Theme.Typography.label).foregroundStyle(Theme.secondary)
                    .padding(.leading, Theme.Metrics.rowPadding)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, Theme.Metrics.contentEdge)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Radius.shape(Theme.Radius.row).fill(resolved.fill(Theme.Fill.group)))
        }
    }
}

/// The hairline between two rows of a group.
struct FormDivider: View {
    var body: some View { Hairline() }
}

struct FormRow<Detail: View, Control: View>: View {
    let label: String
    @ViewBuilder var control: Control
    @ViewBuilder var detail: Detail

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: Theme.Space.hair) {
                Text(label).font(Theme.Typography.body).foregroundStyle(Theme.text)
                detail.font(Theme.Typography.meta).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.md)
            control
        }
        .padding(.vertical, Theme.Space.sm)
        .frame(minHeight: Theme.Metrics.formRow)
    }
}

extension FormRow where Detail == Text? {
    /// A plain sentence under the label, or none.
    init(_ label: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.init(label: label, control: control, detail: { detail.map { Text($0) } })
    }
}

/// A switch row. The label and its detail are one VoiceOver element with the switch's On/Off.
struct FormToggle: View {
    let label: String
    var detail: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: Theme.Space.hair) {
                Text(label).font(Theme.Typography.body).foregroundStyle(Theme.text)
                if let detail {
                    Text(detail).font(Theme.Typography.meta).foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, detail == nil ? 0 : Theme.Space.sm)
        }
        .toggleStyle(SwitchStyle())
    }
}

/// A button that fills its row on hover, for a row that goes somewhere or does something: it reaches 8pt past the
/// group's padding so the fill has room around the text.
struct FormButtonRow<Label: View>: View {
    let action: () -> Void
    @ViewBuilder var label: Label

    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, Theme.Metrics.rowPadding)
                .frame(maxWidth: .infinity, minHeight: Theme.Metrics.formRow, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverFillButtonStyle(shape: Theme.Radius.shape(Theme.Radius.field)))
        .focusRing(Theme.Radius.field)
        .padding(.horizontal, -Theme.Metrics.rowPadding)
    }
}

/// A bordered pop-up button: the current value in plain words and the up/down chevrons, over a menu. The menu is the
/// system's, so it follows the panel's dark appearance. Drawn here because a non-key panel greys the system one.
struct PopUp<Content: View>: View {
    /// What VoiceOver calls it.
    let label: String
    let value: String
    @ViewBuilder var content: Content
    @Environment(\.isEnabled) private var enabled
    @Environment(\.resolved) private var resolved
    @State private var hovering = false

    var body: some View {
        Menu { content } label: {
            HStack(spacing: Theme.Space.sm) {
                Text(value).font(Theme.Typography.control)
                    .foregroundStyle(enabled ? AnyShapeStyle(Theme.text) : AnyShapeStyle(Theme.tertiary))
                Image(systemName: "chevron.up.chevron.down").font(Theme.Typography.glyph(9, .bold)).foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, Theme.Space.md)
            .frame(height: Theme.Metrics.button)
            .background(Theme.Radius.shape(Theme.Radius.tile).fill(resolved.fill(hovering && enabled ? Theme.Fill.selected : Theme.Fill.tile)))
            .overlay(Theme.Radius.shape(Theme.Radius.tile).strokeBorder(Theme.fieldBorder, lineWidth: resolved.borderWidth))
            .contentShape(Theme.Radius.shape(Theme.Radius.tile))
            .onHover { hovering = $0 }
            .motion(Theme.Motion.hover, value: hovering)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusRing(Theme.Radius.tile)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

/// A secret (a token, an API key): Return saves, Esc leaves, and nothing else to press. Focuses itself when asked.
struct SecretField: View {
    let prompt: String
    @Binding var text: String
    var autofocus = false
    var cancel: (() -> Void)? = nil
    let save: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        SecureField(prompt, text: $text)
            .fieldStyle(focused: focused)
            .focused($focused)
            .onSubmit(save)
            .onKeyPress(.escape) {
                guard let cancel else { return .ignored }
                cancel()
                return .handled
            }
            .onAppear { if autofocus { focused = true } }
    }
}

/// A capsule with a label and a remove button of its own.
struct RemovableTag: View {
    let text: String
    let removeLabel: String
    var tip: String? = nil
    let remove: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Text(text).foregroundStyle(Theme.text)
            Button(action: remove) {
                Image(systemName: "xmark").font(Theme.Typography.glyph(9, .bold)).foregroundStyle(Theme.secondary)
                    .frame(width: Theme.Metrics.iconButton, height: Theme.Metrics.iconButton)
            }
            .buttonStyle(HoverFillButtonStyle(shape: Circle()))
            .focusRing(Theme.Metrics.iconButton / 2)
            .accessibilityLabel(removeLabel)
            .help(removeLabel)
        }
        .font(Theme.Typography.control)
        .padding(.leading, Theme.Space.lg)
        .padding(.trailing, Theme.Space.hair)
        .frame(height: Theme.Metrics.iconButton + Theme.Space.xs)
        .background(Capsule().fill(Theme.Fill.tile))
        .help(tip ?? "")
    }
}
