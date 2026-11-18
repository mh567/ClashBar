import SwiftUI

struct MenuBarInteractionStyle: ButtonStyle {
    var cornerRadius = MenuBarLayoutTokens.cornerRadius

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(MenuBarInteraction(cornerRadius: self.cornerRadius, pressed: configuration.isPressed))
            .opacity(self.isEnabled ? 1 : 0.58)
    }
}

private struct MenuBarInteraction: ViewModifier {
    let cornerRadius: CGFloat
    var pressed = false

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: self.cornerRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(self.highlightOpacity))
            }
            .contentShape(Rectangle())
            .onHover { self.isHovered = $0 }
    }

    private var highlightOpacity: Double {
        guard self.isEnabled else { return 0 }
        if self.pressed { return self.colorScheme == .dark ? 0.32 : 0.22 }
        return self.isHovered ? (self.colorScheme == .dark ? 0.22 : 0.14) : 0
    }
}

extension View {
    func menuBarHover(cornerRadius: CGFloat = MenuBarLayoutTokens.cornerRadius) -> some View {
        self.modifier(MenuBarInteraction(cornerRadius: cornerRadius))
    }
}

struct MenuBarRowToggleStyle: ToggleStyle {
    let verticalPadding: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: MenuBarLayoutTokens.space6) {
                configuration.label
                Spacer(minLength: 0)
                Toggle("", isOn: .constant(configuration.isOn))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .menuRowPadding(vertical: self.verticalPadding)
        }
        .buttonStyle(MenuBarInteractionStyle())
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }
}
