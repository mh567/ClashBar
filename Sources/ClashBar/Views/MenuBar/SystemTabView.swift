import SwiftUI

// swiftlint:disable:next type_name
private typealias T = MenuBarLayoutTokens

private struct SettingsSelectionRowConfiguration<Option: Hashable> {
    let title: String
    let symbol: String
    let valueText: String
    let options: [Option]
    let optionTitle: (Option) -> String
    let isSelected: (Option) -> Bool
    let onSelect: (Option) -> Void
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case app
    case core

    var id: String {
        self.rawValue
    }

    var titleKey: String {
        switch self {
        case .app:
            "ui.settings.section.app"
        case .core:
            "ui.settings.section.core"
        }
    }
}

struct SystemTabView: TranslatingView {
    @EnvironmentObject var appViewModel: AppViewModel
    @State private var section: SettingsSection = .app
    @State private var isExceptionsExpanded = false

    func settingsCardHeader(_ title: String, symbol: String) -> some View {
        HStack(spacing: T.space6) {
            Image(systemName: symbol)
                .font(.app(size: T.FontSize.caption, weight: .semibold))
                .foregroundStyle(nativeTertiaryLabel)
            Text(title)
                .font(.app(size: T.FontSize.body, weight: .bold))
                .foregroundStyle(nativeTertiaryLabel)
                .textCase(.uppercase)
            Spacer(minLength: 0)
        }
        .menuRowPadding(vertical: T.space2)
    }

    func settingsRowLabel(symbol: String, title: String) -> some View {
        HStack(spacing: T.space6) {
            Image(systemName: symbol)
                .font(.app(size: T.FontSize.caption, weight: .semibold))
                .foregroundStyle(nativeTertiaryLabel)
                .frame(width: 14, alignment: .center)
            Text(title)
                .font(.app(size: T.FontSize.body, weight: .medium))
                .foregroundStyle(nativePrimaryLabel)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    func settingsToggleRow(
        _ title: String,
        symbol: String,
        isOn: Binding<Bool>,
        isDisabled: Bool = false) -> some View
    {
        Toggle(isOn: isOn) {
            self.settingsRowLabel(symbol: symbol, title: title)
                .layoutPriority(1)
        }
        .toggleStyle(MenuBarRowToggleStyle(verticalPadding: T.space4))
        .disabled(isDisabled)
    }

    func settingsMenuRow(
        _ title: String,
        symbol: String,
        valueText: String,
        controlWidth: CGFloat? = nil,
        popoverWidth: CGFloat? = nil,
        popoverMaxHeight: CGFloat? = nil,
        @ViewBuilder options: @escaping (_ dismiss: @escaping () -> Void) -> some View) -> some View
    {
        let resolvedControlWidth = controlWidth ?? self.settingsMenuControlWidth

        return AttachedPopoverMenu(
            width: popoverWidth ?? resolvedControlWidth,
            maxHeight: popoverMaxHeight)
        { _ in
            HStack(spacing: T.space8) {
                self.settingsRowLabel(symbol: symbol, title: title)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                HStack(spacing: T.space2) {
                    Text(valueText)
                        .foregroundStyle(nativeSecondaryLabel)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.right")
                        .font(.app(size: T.FontSize.caption, weight: .semibold))
                        .foregroundStyle(nativeTertiaryLabel)
                }
                .font(.app(size: T.FontSize.caption, weight: .medium))
                .frame(width: resolvedControlWidth, alignment: .trailing)
            }
            .menuRowPadding(vertical: T.space4)
        } content: { dismiss in
            options(dismiss)
        }
        .accessibilityLabel(title)
        .accessibilityValue(valueText)
    }

    private func settingsSelectionRow(
        _ configuration: SettingsSelectionRowConfiguration<some Hashable>) -> some View
    {
        self.settingsMenuRow(
            configuration.title,
            symbol: configuration.symbol,
            valueText: configuration.valueText)
        { dismiss in
            ForEach(configuration.options, id: \.self) { option in
                AttachedPopoverMenuItem(
                    title: configuration.optionTitle(option),
                    selected: configuration.isSelected(option))
                {
                    configuration.onSelect(option)
                    dismiss()
                }
            }
        }
    }

    var settingsSectionControl: some View {
        HStack(spacing: T.space2) {
            ForEach(SettingsSection.allCases) { item in
                self.settingsSectionButton(item)
            }
        }
        .padding(T.space1)
        .background(self.nativeControlSurface(cornerRadius: T.cornerRadius))
    }

    func settingsSectionButton(_ item: SettingsSection) -> some View {
        let selected = self.section == item
        let overriddenCount = item == .core ? self.appViewModel.configOverrideCount : 0

        return Button {
            self.section = item
        } label: {
            HStack(spacing: T.space4) {
                Text(self.tr(item.titleKey))
                    .font(.app(size: T.FontSize.caption, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                if overriddenCount > 0 {
                    Text("\(overriddenCount)")
                        .font(.app(size: T.FontSize.caption, weight: .semibold))
                        .foregroundStyle(self.nativeAccent.opacity(T.Opacity.solid))
                }
            }
            .foregroundStyle(selected ? self.nativePrimaryLabel : self.nativeSecondaryLabel)
            .frame(maxWidth: .infinity)
            .padding(.vertical, T.space2)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: T.cornerRadius, style: .continuous)
                        .fill(self.nativeBadgeFill)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuBarInteractionStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: T.space6) {
            self.settingsSectionControl

            if self.section == .app {
                self.appSettingsSection
            } else {
                self.coreSettingsSection
            }
        }
        .overlay(alignment: .top) {
            if let feedback = settingsFeedbackState {
                self.settingsFeedbackBanner(
                    text: feedback.message,
                    color: feedback.color,
                    symbol: feedback.symbol)
            }
        }
    }

    // MARK: - App settings

    var appSettingsSection: some View {
        let isRemote = self.appViewModel.isRemoteTarget
        let localOnlyItems: [(id: String, title: String, symbol: String, isOn: Binding<Bool>)] = [
            (
                "launch-at-login",
                tr("ui.settings.launch_at_login"),
                "person.crop.circle.badge.checkmark",
                Binding(
                    get: { self.appViewModel.launchAtLoginEnabled },
                    set: { self.appViewModel.applyLaunchAtLogin($0) })),
            (
                "auto-start-core",
                tr("ui.settings.auto_start_core"),
                "power.circle",
                Binding(
                    get: { self.appViewModel.autoStartCoreEnabled },
                    set: { self.appViewModel.autoStartCoreEnabled = $0 })),
        ]
        let systemProxyExceptionsTitle = isRemote
            ? "\(tr("ui.section.system_proxy_exceptions")) (\(tr("ui.machine.local_label")))"
            : self.tr("ui.section.system_proxy_exceptions")

        return VStack(alignment: .leading, spacing: T.space6) {
            VStack(spacing: 0) {
                self.settingsCardHeader(
                    isRemote ? self.tr("ui.section.local_app_settings") : self.tr("ui.section.basic_settings"),
                    symbol: "slider.horizontal.3")
                ForEach(localOnlyItems, id: \.id) { item in
                    self.settingsToggleRow(
                        isRemote ? "\(item.title) (\(self.tr("ui.machine.local_label")))" : item.title,
                        symbol: item.symbol,
                        isOn: item.isOn)
                }
                self.settingsSelectionRow(.init(
                    title: self.tr("ui.settings.menu_bar_style"),
                    symbol: "menubar.rectangle",
                    valueText: self.statusBarModeLabel(self.appViewModel.statusBarDisplayMode),
                    options: StatusBarDisplayMode.allCases,
                    optionTitle: self.statusBarModeLabel,
                    isSelected: { self.appViewModel.statusBarDisplayMode == $0 },
                    onSelect: { self.appViewModel.statusBarDisplayMode = $0 }))
                self.settingsSelectionRow(.init(
                    title: self.tr("ui.settings.language"),
                    symbol: "character.book.closed",
                    valueText: self.appViewModel.uiLanguage == .zhHans ? self.tr("ui.language.zh_hans") : self
                        .tr("ui.language.en"),
                    options: AppLanguage.allCases,
                    optionTitle: { $0 == .zhHans ? self.tr("ui.language.zh_hans") : self.tr("ui.language.en") },
                    isSelected: { self.appViewModel.uiLanguage == $0 },
                    onSelect: self.appViewModel.setUILanguage))
                self.settingsSelectionRow(.init(
                    title: self.tr("ui.settings.appearance"),
                    symbol: "circle.lefthalf.filled",
                    valueText: self.appearanceModeLabel(self.appViewModel.appearanceMode),
                    options: AppAppearanceMode.allCases,
                    optionTitle: self.appearanceModeLabel,
                    isSelected: { self.appViewModel.appearanceMode == $0 },
                    onSelect: self.appViewModel.setAppearanceMode))
                self.currentCoreModeRow
                self.settingsURLFieldRow(
                    self.tr("ui.settings.direct_healthcheck_url"),
                    symbol: "arrow.triangle.branch",
                    placeholder: AppViewModel.defaultDirectHealthcheckURL,
                    text: self.$appViewModel.directHealthcheckURL)
                Button {
                    self.isExceptionsExpanded.toggle()
                } label: {
                    HStack(spacing: T.space8) {
                        self.settingsRowLabel(
                            symbol: "arrowshape.turn.up.right.circle",
                            title: systemProxyExceptionsTitle)
                            .layoutPriority(1)
                        Spacer(minLength: 0)
                        HStack(spacing: T.space2) {
                            let count = self.appViewModel.systemProxyExceptions.count
                            if count > 0 {
                                Text("\(count)")
                                    .foregroundStyle(nativeSecondaryLabel)
                                    .lineLimit(1)
                            }
                            if !self.appViewModel.isSystemProxyEnabled {
                                Text(self.tr("ui.settings.system_proxy_exceptions.inactive"))
                                    .foregroundStyle(nativeTertiaryLabel)
                                    .lineLimit(1)
                            }
                            Image(systemName: "chevron.right")
                                .font(.app(size: T.FontSize.caption, weight: .semibold))
                                .foregroundStyle(nativeTertiaryLabel)
                                .rotationEffect(.degrees(self.isExceptionsExpanded ? 90 : 0))
                        }
                        .font(.app(size: T.FontSize.caption, weight: .medium))
                    }
                    .menuRowPadding(vertical: T.space4)
                }
                .buttonStyle(MenuBarInteractionStyle())

                self.systemProxyExceptionsEditor
                    .menuRowPadding(vertical: T.space4)
                    .frame(maxHeight: self.isExceptionsExpanded ? .infinity : 0, alignment: .top)
                    .clipped()
                    .opacity(self.isExceptionsExpanded ? 1 : 0)
            }
            .animation(.spring(response: 0.30, dampingFraction: 0.80), value: self.isExceptionsExpanded)

            self.maintenanceSection
        }
    }

    var currentCoreModeRow: some View {
        HStack(spacing: T.space6) {
            self.settingsRowLabel(symbol: "shield.lefthalf.filled", title: self.tr("ui.banner.mode.title"))
                .layoutPriority(1)
            Spacer(minLength: 0)
            Text(self.coreModeLabel(self.appViewModel.currentMode))
                .font(.app(size: T.FontSize.caption, weight: .medium))
                .foregroundStyle(nativeSecondaryLabel)
                .lineLimit(1)
        }
        .menuRowPadding(vertical: T.space4)
        .help(self.tr("ui.settings.core_mode.hint"))
    }

    var systemProxyExceptionsEditor: some View {
        VStack(alignment: .leading, spacing: T.space4) {
            Text(self.tr("ui.settings.system_proxy_exceptions_hint"))
                .font(.app(size: T.FontSize.caption, weight: .regular))
                .foregroundStyle(nativeSecondaryLabel)
                .fixedSize(horizontal: false, vertical: true)

            if self.appViewModel.systemProxyExceptions.isEmpty {
                Text(self.tr("ui.settings.system_proxy_exceptions_empty"))
                    .font(.app(size: T.FontSize.body, weight: .regular))
                    .foregroundStyle(nativeSecondaryLabel)
            } else {
                VStack(alignment: .leading, spacing: T.space4) {
                    ForEach(self.appViewModel.systemProxyExceptions) { item in
                        self.systemProxyExceptionRow(item)
                    }
                }
            }

            HStack(spacing: T.space4) {
                TextField(
                    self.tr("ui.placeholder.system_proxy_exception"),
                    text: self.$appViewModel.systemProxyNewException)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(.app(size: T.FontSize.body, weight: .regular))
                    .foregroundStyle(nativePrimaryLabel)
                    .onSubmit {
                        self.appViewModel.addSystemProxyExceptionDraft()
                    }

                Button(self.tr("ui.action.add_exception")) {
                    self.appViewModel.addSystemProxyExceptionDraft()
                }
                .appBorderedButtonStyle()
                .controlSize(.small)
                .disabled(!self.appViewModel.canAddSystemProxyException || self
                    .isSystemProxyExceptionsSyncing)
            }

            HStack(spacing: T.space4) {
                Button {
                    self.appViewModel.restoreDefaultSystemProxyExceptionsDraft()
                } label: {
                    Label(self.tr("ui.action.restore_defaults"), systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .appBorderedButtonStyle()
                .controlSize(.small)
                .disabled(self.isSystemProxyExceptionsSyncing)

                Button {
                    Task { await self.appViewModel.saveSystemProxyExceptions() }
                } label: {
                    Label(self.tr("ui.action.save_exceptions"), systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .appBorderedButtonStyle()
                .controlSize(.small)
                .disabled(self.isSystemProxyExceptionsSyncing)
            }
        }
    }

    var maintenanceSection: some View {
        let maintenanceActions: [(titleKey: String, symbol: String, action: @MainActor () async -> Void)] = [
            (
                "ui.action.flush_fakeip_cache",
                "externaldrive.badge.minus",
                { await self.appViewModel.flushFakeIPCache() }),
            (
                "ui.action.flush_dns_cache",
                "network.badge.shield.half.filled",
                { await self.appViewModel.flushDNSCache() }),
        ]

        return VStack(spacing: 0) {
            self.settingsCardHeader(
                self.tr("ui.section.maintenance"),
                symbol: "wrench.and.screwdriver")

            VStack(alignment: .leading, spacing: T.space4) {
                HStack(spacing: T.space6) {
                    ForEach(maintenanceActions, id: \.titleKey) { item in
                        self.maintenanceActionButton(self.tr(item.titleKey), symbol: item.symbol) {
                            await item.action()
                        }
                    }
                }

                HStack(spacing: T.space6) {
                    Button {
                        Task { await self.appViewModel.upgradeGeo() }
                    } label: {
                        HStack(spacing: T.space4) {
                            Group {
                                if self.appViewModel.isGeoUpdateInFlight {
                                    ProgressView()
                                        .controlSize(.mini)
                                } else if let symbol = self.geoUpdateFeedbackSymbol {
                                    Image(systemName: symbol)
                                        .foregroundStyle(self.geoUpdateFeedbackColor)
                                } else {
                                    Image(systemName: "arrow.down.circle")
                                }
                            }
                            .frame(width: 16, height: 16)
                            Text(self.tr("ui.action.update_geo_database"))
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .appBorderedButtonStyle()
                    .controlSize(.small)
                    .disabled(!self.geoUpdateActionEnabled)
                    .opacity(self.geoUpdateActionEnabled ? 1 : 0.62)

                    Button {
                        self.appViewModel.showCoreDirectoryInFinder()
                    } label: {
                        Label(self.tr("ui.action.open_core_directory"), systemImage: "folder")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .appBorderedButtonStyle()
                    .controlSize(.small)
                }
            }
            .menuRowPadding(vertical: T.space4)
        }
    }

    // MARK: - Core settings

    var coreSettingsSection: some View {
        VStack(alignment: .leading, spacing: T.space6) {
            if self.showsCoreHeader {
                self.coreHeader
            }
            self.coreFollowHint

            if !self.appViewModel.ungroupedConfigOverrideFieldStates.isEmpty {
                VStack(spacing: 0) {
                    self.settingsCardHeader(
                        self.tr("ui.settings.group.general"),
                        symbol: "slider.horizontal.2.square")
                    ForEach(self.appViewModel.ungroupedConfigOverrideFieldStates) { state in
                        self.coreFieldRow(state)
                    }
                }
            }

            ForEach(ConfigOverrideGroup.allCases) { group in
                self.coreGroupCard(group)
            }
        }
    }

    var showsCoreHeader: Bool {
        self.appViewModel.isRemoteTarget || self.appViewModel.configOverrideCount > 0
    }

    var coreHeader: some View {
        VStack(alignment: .leading, spacing: T.space2) {
            if self.appViewModel.isRemoteTarget {
                Text(self.tr("ui.settings.core_remote_hint"))
                    .font(.app(size: T.FontSize.caption, weight: .regular))
                    .foregroundStyle(nativeSecondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .menuRowPadding(vertical: 0)
            }

            if self.appViewModel.configOverrideCount > 0 {
                HStack(spacing: T.space6) {
                    Spacer(minLength: 0)
                    Button {
                        self.confirmRestoreAllOverrides()
                    } label: {
                        Text(self.tr("ui.settings.overrides.restore_all"))
                            .font(.app(size: T.FontSize.caption, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(self.nativeAccent.opacity(T.Opacity.solid))
                    .disabled(!self.appViewModel.canRestoreConfigField)
                }
                .menuRowPadding(vertical: 0)
            }
        }
    }

    var coreFollowHint: some View {
        HStack(spacing: T.space6) {
            Image(systemName: "info.circle")
                .font(.app(size: T.FontSize.caption, weight: .semibold))
                .foregroundStyle(nativeTertiaryLabel)
            Text(self.tr("ui.settings.overrides.hint"))
                .font(.app(size: T.FontSize.caption, weight: .regular))
                .foregroundStyle(nativeSecondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .menuRowPadding(vertical: T.space4)
        .background {
            RoundedRectangle(cornerRadius: T.cornerRadius, style: .continuous)
                .fill(self.nativeBadgeFill)
        }
    }

    @ViewBuilder
    func coreGroupCard(_ group: ConfigOverrideGroup) -> some View {
        let states = self.appViewModel.configOverrideFieldStates(in: group)
        if !states.isEmpty {
            VStack(spacing: 0) {
                self.settingsCardHeader(self.tr(group.titleKey), symbol: Self.groupSymbol(group))
                if group == .tun {
                    self.coreTunModeRow(states)
                } else {
                    ForEach(states) { state in
                        self.coreFieldRow(state)
                    }
                }
                if group == .tun {
                    self.tunRouteExcludeRow
                }
            }
        }
    }

    /// TUN 开关与协议栈合并为一行：协议栈胶囊在左，开关在右。
    func coreTunModeRow(_ states: [ConfigOverrideFieldState]) -> some View {
        let toggle = states.first { $0.field == .tunEnable }
        let hasStack = states.contains { $0.field == .tunStack }

        return VStack(spacing: 0) {
            HStack(spacing: T.space6) {
                self.settingsRowLabel(symbol: "shield.lefthalf.filled", title: self.tr("ui.quick.tun_mode"))
                    .layoutPriority(1)
                Spacer(minLength: 0)
                if hasStack {
                    self.tunStackChips()
                }
                if let toggle {
                    Toggle("", isOn: Binding(
                        get: { self.appViewModel.isTunEnabled },
                        set: { value in
                            Task { await self.appViewModel.toggleTunMode(value) }
                        }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(self.coreFieldDisabled || !self.appViewModel.isTunToggleEnabled)
                        .accessibilityLabel(self.tr(toggle.field.titleKey))
                }
            }
            .menuRowPadding(vertical: T.space4)

            self.coreFieldOverrideChips(states)
        }
    }

    /// Shows one restore chip per overridden field in a merged row, so both the
    /// TUN toggle and its stack stay individually recoverable. The chip text names
    /// the field, otherwise two identical "已覆盖" chips would be indistinguishable.
    @ViewBuilder
    func coreFieldOverrideChips(_ states: [ConfigOverrideFieldState]) -> some View {
        let overridden = states.filter(\.isOverridden)
        if !overridden.isEmpty {
            HStack(spacing: T.space4) {
                Spacer(minLength: 0)
                ForEach(overridden) { state in
                    self.coreFieldStatus(state, showsFieldName: true)
                }
            }
            .menuRowPadding(vertical: 0)
            .padding(.bottom, T.space4)
        }
    }

    func tunStackChips() -> some View {
        HStack(spacing: T.space2) {
            ForEach(ProxyTabView.tunStackOptions, id: \.self) { option in
                self.tunStackChip(option)
            }
        }
        .opacity(self.appViewModel.isTunEnabled ? 1 : 0.55)
        .help(self.tr("ui.quick.tun_stack_switch_hint"))
    }

    func tunStackChip(_ option: String) -> some View {
        let active = self.appViewModel.tunStack?.caseInsensitiveCompare(option) == .orderedSame
        let unsupported = option.caseInsensitiveCompare("mips") == .orderedSame
            && !self.appViewModel.isMipsStackSupported
        let enabled = self.coreFieldDisabled == false
            && self.appViewModel.isTunToggleEnabled
            && !unsupported
        let fill = active && self.appViewModel.isTunEnabled
            ? self.nativePositive.opacity(T.Opacity.tint)
            : self.nativeBadgeFill
        let foreground = active && self.appViewModel.isTunEnabled
            ? self.nativePositive.opacity(T.Opacity.solid)
            : self.nativeSecondaryLabel

        return Button {
            guard enabled else { return }
            Task { await self.appViewModel.selectTunStack(option) }
        } label: {
            Text(option)
                .font(.app(size: T.FontSize.caption, weight: active ? .semibold : .medium))
                .foregroundStyle(foreground)
                .lineLimit(1)
                .padding(.horizontal, T.space4)
                .padding(.vertical, T.space1)
                .background {
                    Capsule(style: .continuous).fill(fill)
                }
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .fixedSize()
        .help(unsupported
            ? self.tr("app.tun.mips_requires_upgrade", AppViewModel.mipsStackMinimumCoreVersion)
            : self.tr("ui.quick.tun_stack_switch_hint"))
    }

    var tunRouteExcludeRow: some View {
        let display = self.appViewModel.tunRouteExcludeAddressDisplay
        return HStack(alignment: .firstTextBaseline, spacing: T.space6) {
            self.settingsRowLabel(
                symbol: "arrow.uturn.backward.circle",
                title: self.tr("ui.settings.route_exclude.title"))

            Spacer(minLength: 0)

            Text(display.lines.isEmpty
                ? self.tr("ui.settings.route_exclude.empty")
                : display.lines.joined(separator: "  "))
                .font(.app(size: T.FontSize.caption, weight: .regular))
                .foregroundStyle(display.lines.isEmpty ? self.nativeTertiaryLabel : self.nativeSecondaryLabel)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            Text(self.tr(display.fromCore
                ? "ui.settings.route_exclude.source.core"
                : "ui.settings.route_exclude.source.yaml"))
                .font(.app(size: T.FontSize.caption, weight: .regular))
                .foregroundStyle(nativeTertiaryLabel)
                .fixedSize()
        }
        .menuRowPadding(vertical: T.space4)
        .help(self.tr("ui.settings.route_exclude.hint"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.tr("ui.settings.route_exclude.title"))
    }

    static func groupSymbol(_ group: ConfigOverrideGroup) -> String {
        switch group {
        case .network:
            "network"
        case .ports:
            "point.3.connected.trianglepath.dotted"
        case .tun:
            "shield.lefthalf.filled"
        }
    }

    @ViewBuilder
    func coreFieldRow(_ state: ConfigOverrideFieldState) -> some View {
        switch state.field {
        case .allowLan, .ipv6, .tcpConcurrent:
            self.coreToggleFieldRow(state)
        case .port, .socksPort, .mixedPort, .redirPort, .tproxyPort:
            self.corePortFieldRow(state)
        case .logLevel:
            self.coreLogLevelRow(state)
        case .tunEnable, .tunStack:
            // Rendered together by `coreTunModeRow`.
            EmptyView()
        }
    }

    func coreToggleFieldRow(_ state: ConfigOverrideFieldState) -> some View {
        let setting = Self.coreSetting(for: state.field)
        return self.coreRow(state) {
            Toggle("", isOn: Binding(
                get: { setting.map { self.appViewModel.boolValue(for: $0) } ?? false },
                set: { value in
                    guard let setting else { return }
                    Task { await self.appViewModel.applyEditableCoreSetting(setting, to: value) }
                }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(self.coreFieldDisabled)
                .accessibilityLabel(self.tr(state.field.titleKey))
        }
    }

    func corePortFieldRow(_ state: ConfigOverrideFieldState) -> some View {
        self.coreRow(state) {
            TextField(self.tr("ui.placeholder.port"), text: Binding(
                get: {
                    self.appViewModel.editedProxyPorts[state.field.rawValue] ?? Self.portText(state.field, view: self)
                },
                set: {
                    self.appViewModel.editedProxyPorts[state.field.rawValue] = $0
                    self.appViewModel.scheduleProxyPortsAutoSaveIfNeeded()
                }))
                .textFieldStyle(.roundedBorder)
                .font(.app(size: T.FontSize.body, weight: .regular))
                .foregroundStyle(nativePrimaryLabel)
                .multilineTextAlignment(.trailing)
                .frame(width: self.settingsPortFieldWidth, alignment: .trailing)
                .onSubmit {
                    self.appViewModel.editedProxyPorts[state.field.rawValue] =
                        self.appViewModel.editedProxyPorts[state.field.rawValue]
                            ?? Self.portText(state.field, view: self)
                    Task { await self.appViewModel.applyProxyPorts() }
                }
                .disabled(self.coreFieldDisabled)
        }
    }

    func coreLogLevelRow(_ state: ConfigOverrideFieldState) -> some View {
        let current = self.appViewModel.stringValue(for: .logLevel)
        return self.coreRow(state) {
            self.coreValueMenu(current, disabled: self.coreFieldDisabled) { dismiss in
                ForEach(ConfigLogLevel.allCases, id: \.self) { level in
                    AttachedPopoverMenuItem(
                        title: level.rawValue,
                        selected: current.caseInsensitiveCompare(level.rawValue) == .orderedSame)
                    {
                        Task { await self.appViewModel.applyEditableCoreSetting(.logLevel, to: level.rawValue) }
                        dismiss()
                    }
                }
            }
        }
    }

    /// One core row: label on the left, then the control and override chip on the
    /// right edge. The chip follows the control so the interactive element stays
    /// in a stable position across rows.
    func coreRow(
        _ state: ConfigOverrideFieldState,
        @ViewBuilder control: () -> some View) -> some View
    {
        HStack(spacing: T.space6) {
            self.settingsRowLabel(symbol: state.field.symbol, title: self.tr(state.field.titleKey))
                .layoutPriority(1)
            Spacer(minLength: 0)
            control()
            self.coreFieldStatus(state)
        }
        .menuRowPadding(vertical: T.space4)
    }

    func coreValueMenu(
        _ value: String,
        disabled: Bool,
        @ViewBuilder options: @escaping (_ dismiss: @escaping () -> Void) -> some View) -> some View
    {
        AttachedPopoverMenu(width: self.settingsPopoverWidth) { _ in
            HStack(spacing: T.space2) {
                Text(value)
                    .foregroundStyle(nativeSecondaryLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.right")
                    .font(.app(size: T.FontSize.caption, weight: .semibold))
                    .foregroundStyle(nativeTertiaryLabel)
            }
            .font(.app(size: T.FontSize.caption, weight: .medium))
            .fixedSize()
            .contentShape(Rectangle())
        } content: { dismiss in
            options(dismiss)
        }
        .disabled(disabled)
    }

    static func portText(_ field: ConfigOverrideField, view: SystemTabView) -> String {
        switch field {
        case .port:
            view.appViewModel.settingsPort
        case .socksPort:
            view.appViewModel.settingsSocksPort
        case .mixedPort:
            view.appViewModel.settingsMixedPort
        case .redirPort:
            view.appViewModel.settingsRedirPort
        default:
            view.appViewModel.settingsTProxyPort
        }
    }

    @ViewBuilder
    func coreFieldStatus(
        _ state: ConfigOverrideFieldState,
        showsFieldName: Bool = false) -> some View
    {
        if state.isOverridden {
            Button {
                Task { await self.appViewModel.restoreConfigField(state.field.rawValue) }
            } label: {
                Text(self.coreStatusChipText(state, showsFieldName: showsFieldName))
                    .font(.app(size: T.FontSize.caption, weight: .medium))
                    .padding(.horizontal, T.space4)
                    .padding(.vertical, T.space1)
                    .background {
                        Capsule(style: .continuous)
                            .fill(self.coreStatusTint(state).opacity(T.Opacity.tint))
                    }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(self.coreStatusTint(state).opacity(T.Opacity.solid))
            .disabled(!self.appViewModel.canRestoreConfigField)
            .help(self.coreRestoreHelp(state))
            .fixedSize()
            .accessibilityLabel(self.coreRestoreHelp(state))
        } else {
            Text(self.tr("ui.settings.overrides.status.following_short"))
                .font(.app(size: T.FontSize.caption, weight: .regular))
                .foregroundStyle(self.nativeTertiaryLabel)
                .fixedSize()
                .accessibilityLabel(self.tr("ui.settings.overrides.status.following"))
        }
    }

    func coreStatusChipText(_ state: ConfigOverrideFieldState, showsFieldName: Bool) -> String {
        let status = self.tr(state.isUnconfirmed
            ? "ui.settings.overrides.status.unconfirmed_short"
            : "ui.settings.overrides.status.overridden_short")
        guard showsFieldName else { return status }
        return self.tr("ui.settings.overrides.status.chip_named", self.tr(state.field.titleKey), status)
    }

    func coreRestoreHelp(_ state: ConfigOverrideFieldState) -> String {
        let title = self.tr(state.field.titleKey)
        guard state.showsDifference, let declared = state.declaredText else {
            return self.tr("ui.settings.overrides.item.restore_help", title)
        }
        return self.tr("ui.settings.overrides.item.restore_help_with_declared", title, declared)
    }

    func coreStatusTint(_ state: ConfigOverrideFieldState) -> Color {
        state.isUnconfirmed
            ? self.nativeWarning
            : self.nativeAccent
    }

    var coreFieldDisabled: Bool {
        self.appViewModel.isCoreSettingSyncing || self.appViewModel.isConfigMutationBusy
    }

    static func coreSetting(for field: ConfigOverrideField) -> AppViewModel.EditableCoreSetting? {
        switch field {
        case .allowLan:
            .allowLan
        case .ipv6:
            .ipv6
        case .tcpConcurrent:
            .tcpConcurrent
        case .logLevel:
            .logLevel
        default:
            nil
        }
    }

    func confirmRestoreAllOverrides() {
        let count = self.appViewModel.configOverrideCount
        guard count > 0 else { return }
        let response = self.appViewModel.runModalAlert(
            style: .informational,
            message: self.tr("ui.settings.overrides.restore_all_confirm.title"),
            informative: self.tr("ui.settings.overrides.restore_all_confirm.message", count),
            buttons: [
                self.tr("ui.settings.overrides.restore_all"),
                self.tr("ui.action.cancel"),
            ])
        guard response == .alertFirstButtonReturn else { return }
        Task { await self.appViewModel.restoreAllConfigFields() }
    }

    var settingsPopoverWidth: CGFloat {
        min(300, T.panelWidth - (T.space8 * 2))
    }

    // MARK: - Rows and helpers

    func settingsURLFieldRow(
        _ title: String,
        symbol: String,
        placeholder: String,
        text: Binding<String>) -> some View
    {
        HStack(spacing: T.space8) {
            self.settingsRowLabel(symbol: symbol, title: title)
                .layoutPriority(1)

            Spacer(minLength: 0)

            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.app(size: T.FontSize.caption, weight: .regular))
                .foregroundStyle(nativePrimaryLabel)
                .multilineTextAlignment(.trailing)
                .frame(width: self.settingsMenuControlWidth, alignment: .trailing)
                .help(placeholder)
        }
        .menuRowPadding(vertical: T.space4)
    }

    func systemProxyExceptionBinding(id: EditableSystemProxyException.ID) -> Binding<String> {
        Binding(
            get: {
                self.appViewModel.systemProxyExceptions.first(where: { $0.id == id })?.value ?? ""
            },
            set: { value in
                guard let index = self.appViewModel.systemProxyExceptions.firstIndex(where: { $0.id == id }) else {
                    return
                }
                self.appViewModel.systemProxyExceptions[index].value = value
            })
    }

    func systemProxyExceptionRow(_ exception: EditableSystemProxyException) -> some View {
        HStack(spacing: T.space4) {
            TextField(
                self.tr("ui.placeholder.system_proxy_exception"),
                text: self.systemProxyExceptionBinding(id: exception.id))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.app(size: T.FontSize.body, weight: .regular))
                .foregroundStyle(nativePrimaryLabel)

            Button {
                self.appViewModel.removeSystemProxyExceptionDraft(id: exception.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(nativeCritical.opacity(T.Opacity.solid))
            }
            .buttonStyle(.borderless)
            .menuBarHover()
            .accessibilityLabel(self.tr("ui.action.remove_exception"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func maintenanceActionButton(_ title: String, symbol: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Label {
                Text(title)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
            } icon: {
                Image(systemName: symbol)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .appBorderedButtonStyle()
        .controlSize(.small)
        .disabled(!self.maintenanceActionEnabled)
        .opacity(self.maintenanceActionEnabled ? 1 : 0.62)
    }

    func settingsFeedbackBanner(text: String, color: Color, symbol: String) -> some View {
        HStack(spacing: T.space6) {
            Image(systemName: symbol)
                .font(.app(size: T.FontSize.caption, weight: .semibold))
                .foregroundStyle(color)

            Text(text)
                .font(.app(size: T.FontSize.caption, weight: .medium))
                .foregroundStyle(nativePrimaryLabel)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
        .menuRowPadding(vertical: T.space4)
        .background {
            RoundedRectangle(cornerRadius: T.cornerRadius, style: .continuous)
                .fill(nativeControlFill)
                .overlay {
                    RoundedRectangle(cornerRadius: T.cornerRadius, style: .continuous)
                        .stroke(color.opacity(0.26), lineWidth: T.stroke)
                }
                .shadow(
                    color: self.nativeShadow.opacity(T.Shadow.standard.opacity),
                    radius: T.Shadow.standard.radius,
                    x: T.Shadow.standard.x,
                    y: T.Shadow.standard.y)
        }
    }

    func coreModeLabel(_ mode: CoreMode) -> String {
        switch mode {
        case .rule:
            self.tr("ui.mode.rule")
        case .global:
            self.tr("ui.mode.global")
        case .direct:
            self.tr("ui.mode.direct")
        }
    }

    func statusBarModeLabel(_ mode: StatusBarDisplayMode) -> String {
        switch mode {
        case .iconAndSpeed:
            self.tr("ui.settings.display_mode.icon_and_speed")
        case .iconOnly:
            self.tr("ui.settings.display_mode.icon_only")
        case .speedOnly:
            self.tr("ui.settings.display_mode.speed_only")
        }
    }

    func appearanceModeLabel(_ mode: AppAppearanceMode) -> String {
        switch mode {
        case .system:
            self.tr("ui.settings.appearance.system")
        case .light:
            self.tr("ui.settings.appearance.light")
        case .dark:
            self.tr("ui.settings.appearance.dark")
        }
    }

    var settingsMenuControlWidth: CGFloat {
        let contentWidth = T.panelWidth - (T.space8 * 2)
        return min(152, max(118, contentWidth * 0.43))
    }

    var settingsPortFieldWidth: CGFloat {
        let contentWidth = T.panelWidth - (T.space8 * 2)
        return min(108, max(92, contentWidth * 0.30))
    }

    var maintenanceActionEnabled: Bool {
        SystemTabViewModel.maintenanceActionEnabled(session: self.appViewModel)
    }

    var geoUpdateActionEnabled: Bool {
        self.appViewModel.isRuntimeRunning && !self.appViewModel.isGeoUpdateInFlight
    }

    var geoUpdateFeedbackSymbol: String? {
        switch self.appViewModel.geoUpdateState {
        case .idle, .updating:
            nil
        case .succeeded:
            "checkmark.circle"
        case .failed:
            "exclamationmark.triangle"
        }
    }

    var geoUpdateFeedbackColor: Color {
        switch self.appViewModel.geoUpdateState {
        case .succeeded:
            nativePositive.opacity(T.Opacity.solid)
        case .failed:
            nativeCritical.opacity(T.Opacity.solid)
        default:
            nativeSecondaryLabel
        }
    }

    var isSystemProxyExceptionsSyncing: Bool {
        self.appViewModel.settingsSyncingKey == "system-proxy-exceptions"
    }

    var settingsFeedbackState: (message: String, color: Color, symbol: String)? {
        guard let feedback = SystemTabViewModel.feedbackState(session: appViewModel) else { return nil }
        let color: Color = switch feedback.kind {
        case .error:
            nativeCritical.opacity(T.Opacity.solid)
        case .warning:
            nativeWarning.opacity(T.Opacity.solid)
        case .success:
            nativePositive.opacity(T.Opacity.solid)
        }
        return (feedback.message, color, feedback.symbol)
    }
}
