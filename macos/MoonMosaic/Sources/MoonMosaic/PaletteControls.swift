import SwiftUI

// Controls drawn in the palette's colours, so night mode stays red: the
// system's checkboxes, switches, segmented pickers, pop-up menus, steppers
// and sliders keep their daytime greys, blues and whites.

/// A checkbox in the palette's colours.
struct PaletteCheckbox: ToggleStyle {
    let palette: Palette

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(configuration.isOn ? palette.bright : palette.panel)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(palette.dim, lineWidth: 1))
                    .overlay(
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(palette.background).opacity(configuration.isOn ? 1 : 0)
                    )
                    .frame(width: 14, height: 14)
                configuration.label.foregroundStyle(palette.text)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A small on/off switch in the palette's colours.
struct PaletteSwitch: ToggleStyle {
    let palette: Palette

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                configuration.label.foregroundStyle(palette.text)
                Capsule()
                    .fill(configuration.isOn ? palette.bright : palette.panel)
                    .overlay(Capsule().stroke(palette.dim, lineWidth: 1))
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(configuration.isOn ? palette.background : palette.text)
                            .padding(2)
                    }
                    .frame(width: 32, height: 18)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A segmented choice in the palette's colours: the chosen segment filled.
struct PaletteSegmented<T: Hashable>: View {
    let options: [(value: T, label: String)]
    @Binding var selection: T
    let palette: Palette
    var fontSize: CGFloat = 13

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, option in
                let chosen = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.system(size: fontSize, weight: chosen ? .semibold : .regular))
                        .lineLimit(1)
                        .foregroundStyle(chosen ? palette.background : palette.text)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .padding(.horizontal, 8)
                        .background(chosen ? palette.bright : palette.panel)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if i < options.count - 1 {
                    Rectangle().fill(palette.dim).frame(width: 1)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.dim, lineWidth: 1))
    }
}

/// A pop-up choice in the palette's colours (its menu, while open, is the
/// system's).
struct PaletteMenu<T: Hashable>: View {
    let options: [(value: T, label: String)]
    @Binding var selection: T
    let palette: Palette

    var body: some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button(option.label) { selection = option.value }
            }
        } label: {
            HStack(spacing: 6) {
                Text(options.first(where: { $0.value == selection })?.label ?? "—")
                    .lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(palette.text)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(palette.text)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(palette.panel))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.dim, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(minHeight: 24)
    }
}

/// A label with small − and + keys, in the palette's colours.
struct PaletteStepper: View {
    let title: String
    let palette: Palette
    let down: () -> Void
    let up: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(title).monospacedDigit().foregroundStyle(palette.text).lineLimit(1)
            ForEach([("−", down), ("+", up)], id: \.0) { label, action in
                Button(action: action) {
                    Text(label).font(.system(size: 14, weight: .semibold, design: .rounded))
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(BigButton(palette: palette))
            }
        }
    }
}
