import SwiftUI

// swiftlint:disable:next type_name
private typealias T = MenuBarLayoutTokens

/// TUN stack chips shared by the proxy quick rows and the kernel settings page.
///
/// Both places must look and behave identically; keeping two copies is what let
/// them drift apart (one hovered, one did not).
struct TunStackChipsView: TranslatingView {
    @EnvironmentObject var appViewModel: AppViewModel

    let isTunEnabled: Bool
    /// Caller-specific extra gate (for example a settings page that is mid-sync).
    /// The core availability check lives inside, so both call sites agree.
    var isInteractionEnabled: Bool = true
    var selection: String?
    var stagesChanges = false
    let onSelect: (String) -> Void

    static let options = ["system", "gvisor", "mixed", "mips"]

    var body: some View {
        HStack(spacing: T.space2) {
            ForEach(Self.options, id: \.self) { option in
                self.chip(option)
            }
        }
    }

    func chip(_ option: String) -> some View {
        let active = (self.isTunEnabled || self.stagesChanges)
            && (self.selection ?? self.appViewModel.tunStack)?.caseInsensitiveCompare(option) == .orderedSame
        let mipsUnsupported = option.caseInsensitiveCompare("mips") == .orderedSame
            && !self.appViewModel.isMipsStackSupported
        let enabled = self.isInteractionEnabled
            && self.appViewModel.isTunToggleEnabled
            && !mipsUnsupported
        let hint = mipsUnsupported
            ? self.tr("app.tun.mips_requires_upgrade", AppViewModel.mipsStackMinimumCoreVersion)
            : self.tr(self.stagesChanges ? "ui.settings.core.select_stack" : "ui.quick.tun_stack_switch_hint")
        let fill = active ? self.nativePositive.opacity(T.Opacity.tint) : self.nativeBadgeFill
        let border = active
            ? self.nativePositive.opacity(0.18)
            : self.nativeControlBorder.opacity(0.42)
        let foreground = active ? self.nativePositive.opacity(T.Opacity.solid) : self.nativeSecondaryLabel

        let activate = {
            guard enabled else { return }
            self.onSelect(option)
        }

        return Text(option)
            .font(.app(size: T.FontSize.caption, weight: active ? .semibold : .medium))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, T.space4)
            .padding(.vertical, T.space2)
            .background {
                Capsule(style: .continuous)
                    .fill(fill)
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(border, lineWidth: T.stroke)
                    }
            }
            .contentShape(Capsule(style: .continuous))
            .opacity(enabled ? 1 : 0.5)
            .onTapGesture(count: self.stagesChanges ? 1 : 2, perform: activate)
            .menuBarHover(cornerRadius: T.rowHeight / 2)
            .disabled(!enabled)
            .help(hint)
            .accessibilityLabel(option)
            .accessibilityHint(hint)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { activate() }
    }
}
