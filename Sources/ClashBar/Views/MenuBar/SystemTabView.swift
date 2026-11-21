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
    @FocusState private var focusedProxyException: EditableSystemProxyException.ID?

    func settingsCardHeader(_ title: String) -> some View {
        HStack(spacing: T.space6) {
            Text(title)
                .font(.app(size: T.FontSize.body, weight: .bold))
                .foregroundStyle(nativeTertiaryLabel)
                .textCase(.uppercase)
            Spacer(minLength: 0)
        }
        .menuRowPadding(vertical: T.space2)
    }

    static let settingsRowIconWidth: CGFloat = 14

    func settingsRowLabel(symbol: String, title: String) -> some View {
        HStack(spacing: T.space6) {
            Image(systemName: symbol)
                .font(.app(size: T.FontSize.caption, weight: .semibold))
                .foregroundStyle(nativeTertiaryLabel)
                .frame(width: Self.settingsRowIconWidth, alignment: .center)
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
        .onChange(of: self.focusedProxyException) { [focusedProxyException] _ in
            if focusedProxyException != nil {
                self.appViewModel.saveSystemProxyExceptions()
            }
        }
        .onDisappear {
            if self.focusedProxyException != nil {
                self.appViewModel.saveSystemProxyExceptions()
            }
        }
        .overlay(alignment: .top) {
            if self.section == .app, let feedback = settingsFeedbackState {
                self.settingsFeedbackBanner(
                    text: feedback.message,
                    color: feedback.color,
                    symbol: feedback.symbol)
                    .allowsHitTesting(false)
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
                    isRemote ? self.tr("ui.section.local_app_settings") : self.tr("ui.section.basic_settings"))
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
                        self.addSystemProxyException()
                    }

                Button(self.tr("ui.action.add_exception")) {
                    self.addSystemProxyException()
                }
                .appBorderedButtonStyle()
                .controlSize(.small)
                .disabled(!self.appViewModel.canAddSystemProxyException)
            }

            HStack(spacing: T.space4) {
                Button {
                    self.appViewModel.restoreDefaultSystemProxyExceptionsDraft()
                    self.appViewModel.saveSystemProxyExceptions()
                } label: {
                    Label(self.tr("ui.action.restore_defaults"), systemImage: "arrow.counterclockwise")
                }
                .appBorderedButtonStyle()
                .controlSize(.small)

                if self.appViewModel.systemProxyExceptionsError != nil {
                    Button(self.tr("ui.settings.exceptions.retry")) {
                        self.appViewModel.saveSystemProxyExceptions()
                    }
                    .appBorderedButtonStyle()
                    .controlSize(.small)
                }
            }

            if let error = self.appViewModel.systemProxyExceptionsError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.app(size: T.FontSize.caption, weight: .regular))
                    .foregroundStyle(nativeCritical)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(self.appViewModel.isConfigMutationBusy)
    }

    func addSystemProxyException() {
        self.appViewModel.addSystemProxyExceptionDraft()
        self.appViewModel.saveSystemProxyExceptions()
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
            self.settingsCardHeader(self.tr("ui.section.maintenance"))

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
            self.coreSettingsActions

            // Log level is the most frequently changed field, so it sits above the
            // groups with no section header of its own.
            ForEach(self.appViewModel.ungroupedConfigOverrideFieldStates) { state in
                self.coreFieldRow(state)
            }

            ForEach(ConfigOverrideGroup.allCases) { group in
                self.coreGroupCard(group)
            }
        }
    }

    var coreSettingsActions: some View {
        let count = self.appViewModel.pendingCoreSettingsCount
        let applying = self.appViewModel.isApplyingCoreSettings
        let restoring = !self.appViewModel.coreSettingsRestores.isEmpty

        return VStack(alignment: .leading, spacing: T.space6) {
            if applying {
                HStack(spacing: T.space6) {
                    ProgressView().controlSize(.small)
                    Text(self.tr("ui.settings.core.applying"))
                }
            } else if count > 0 {
                Text(self.tr("ui.settings.core.pending", count))
                    .fontWeight(.semibold)
            }
            Text(self.tr(restoring
                ? "ui.settings.core.reload_hint"
                : self.appViewModel.isRemoteTarget ? "ui.settings.core_remote_hint" : "ui.settings.overrides.hint"))
                .foregroundStyle(nativeSecondaryLabel)
                .fixedSize(horizontal: false, vertical: true)

            if let error = self.appViewModel.coreSettingsError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(nativeCritical)
                    .fixedSize(horizontal: false, vertical: true)
            } else if self.appViewModel.settingsSavedMessage == self.tr("ui.settings.core.applied") {
                Label(self.tr("ui.settings.core.applied"), systemImage: "checkmark.circle")
                    .foregroundStyle(nativePositive)
            }

            HStack(spacing: T.space4) {
                if self.appViewModel.configOverrideCount > 0 {
                    Button {
                        self.appViewModel.stageCoreSettingsRestore(Set(self.appViewModel.activeConfigOverrides.keys))
                    } label: {
                        Text(self.tr("ui.settings.overrides.restore_all"))
                            .frame(minHeight: T.compactRowHeight)
                            .padding(.horizontal, T.space6)
                    }
                    .buttonStyle(MenuBarInteractionStyle())
                    .background(self.nativeControlSurface())
                    .disabled(!self.appViewModel.canRestoreConfigField
                        || self.appViewModel.coreSettingsRestores.count == self.appViewModel.configOverrideCount)
                    .help(self.tr("ui.settings.core.restore_all_help"))
                }
                Spacer(minLength: 0)
                if count > 0 {
                    Button(self.tr("ui.settings.core.discard")) {
                        self.appViewModel.discardCoreSettings()
                    }
                    .appBorderedButtonStyle()
                    .disabled(applying)
                }
                Button(self.tr("ui.settings.core.apply")) {
                    Task { await self.appViewModel.applyCoreSettings() }
                }
                .appBorderedButtonStyle(prominent: true)
                .disabled(count == 0 || !self.appViewModel.canApplyCoreSettings
                    || (restoring && !self.appViewModel.canRestoreConfigField))
            }
            .controlSize(.small)
        }
        .font(.app(size: T.FontSize.caption, weight: .regular))
        .menuRowPadding(vertical: T.space6)
        .background {
            RoundedRectangle(cornerRadius: T.cornerRadius, style: .continuous)
                .fill(self.nativeBadgeFill)
        }
    }

    @ViewBuilder
    func coreGroupCard(_ group: ConfigOverrideGroup) -> some View {
        let states = self.appViewModel.configOverrideFieldStates(in: group)
        if !states.isEmpty {
            let plain = states.filter { !$0.field.isTunSetting }
            let tun = states.filter(\.field.isTunSetting)

            VStack(spacing: 0) {
                self.settingsCardHeader(self.tr(group.titleKey))
                ForEach(plain) { state in
                    self.coreFieldRow(state)
                }
                if !tun.isEmpty {
                    self.coreTunModeRow(tun)
                    self.tunRouteExcludeRow
                }
            }
        }
    }

    /// TUN 开关与协议栈合并为一行：协议栈胶囊在左，开关在右。
    /// 两个控件各自带悬停反馈，整行不再叠加一层背景。
    func coreTunModeRow(_ states: [ConfigOverrideFieldState]) -> some View {
        let toggle = states.first { $0.field == .tunEnable }
        let hasStack = states.contains { $0.field == .tunStack }
        let enabled = self.appViewModel.coreSettingValue(.tunEnable) == .bool(true)
        let stack = self.coreSettingText(.tunStack)

        return VStack(spacing: 0) {
            HStack(spacing: T.space6) {
                self.settingsRowLabel(symbol: "shield.lefthalf.filled", title: self.tr("ui.quick.tun_mode"))
                    .layoutPriority(1)
                Spacer(minLength: 0)
                if hasStack {
                    TunStackChipsView(
                        isTunEnabled: enabled,
                        isInteractionEnabled: !self.coreFieldDisabled,
                        selection: stack,
                        stagesChanges: true)
                    { option in
                        self.appViewModel.stageCoreSetting(.tunStack, value: .string(option))
                    }
                }
                if let toggle {
                    Toggle("", isOn: Binding(
                        get: { self.appViewModel.coreSettingValue(.tunEnable) == .bool(true) },
                        set: { self.appViewModel.stageCoreSetting(.tunEnable, value: .bool($0)) }))
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
        let overridden = states.filter { $0.isOverridden || self.appViewModel.coreSettingsEdits[$0.field] != nil }
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

    static let settingsRowTextInset: CGFloat = Self.settingsRowIconWidth + T.space6

    var tunRouteExcludeRow: some View {
        let display = self.appViewModel.tunRouteExcludeAddressDisplay
        return VStack(alignment: .leading, spacing: T.space2) {
            HStack(spacing: T.space6) {
                Text(self.tr("ui.settings.route_exclude.title"))
                    .font(.app(size: T.FontSize.body, weight: .medium))
                    .foregroundStyle(nativePrimaryLabel)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(self.tr(display.fromCore
                    ? "ui.settings.route_exclude.source.core"
                    : "ui.settings.route_exclude.source.yaml"))
                    .font(.app(size: T.FontSize.caption, weight: .regular))
                    .foregroundStyle(nativeTertiaryLabel)
                    .fixedSize()
            }
            .padding(.leading, Self.settingsRowTextInset)

            if display.lines.isEmpty {
                Text(self.tr("ui.settings.route_exclude.empty"))
                    .font(.app(size: T.FontSize.caption, weight: .regular))
                    .foregroundStyle(nativeTertiaryLabel)
                    .padding(.leading, Self.settingsRowTextInset)
            } else {
                // Wrap the whole list: truncating an exclusion list defeats the
                // point of showing which subnets stay out of the tunnel.
                FlexibleWrapLayout(spacing: T.space4) {
                    ForEach(display.lines, id: \.self) { line in
                        Text(line)
                            .font(.app(size: T.FontSize.caption, weight: .regular))
                            .foregroundStyle(nativeSecondaryLabel)
                            .padding(.horizontal, T.space4)
                            .padding(.vertical, T.space1)
                            .background {
                                RoundedRectangle(cornerRadius: T.space4, style: .continuous)
                                    .fill(self.nativeBadgeFill)
                            }
                    }
                }
                .padding(.leading, Self.settingsRowTextInset)
            }

            Text(self.tr("ui.settings.route_exclude.hint"))
                .font(.app(size: T.FontSize.caption, weight: .regular))
                .foregroundStyle(nativeTertiaryLabel)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, Self.settingsRowTextInset)
        }
        .menuRowPadding(vertical: T.space4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.tr("ui.settings.route_exclude.title"))
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
        case .mode:
            self.coreModeRow(state)
        case .tunEnable, .tunStack:
            // Rendered together by `coreTunModeRow`.
            EmptyView()
        }
    }

    func coreModeRow(_ state: ConfigOverrideFieldState) -> some View {
        let current = self.appViewModel.coreSettingValue(.mode)
        return self.coreMenuRow(state, valueText: self.coreSettingText(.mode))
        { dismiss in
            ForEach(Self.modeOptions, id: \.self) { mode in
                AttachedPopoverMenuItem(
                    title: ConfigOverrideField.modeText(mode.rawValue, language: self.language),
                    selected: current == .string(mode.rawValue))
                {
                    self.appViewModel.stageCoreSetting(.mode, value: .string(mode.rawValue))
                    dismiss()
                }
            }
        }
    }

    static let modeOptions: [CoreMode] = [.rule, .global, .direct]

    func coreToggleFieldRow(_ state: ConfigOverrideFieldState) -> some View {
        HStack(spacing: 0) {
            Toggle(isOn: Binding(
                get: { self.appViewModel.coreSettingValue(state.field) == .bool(true) },
                set: { self.appViewModel.stageCoreSetting(state.field, value: .bool($0)) }))
            {
                self.settingsRowLabel(symbol: state.field.symbol, title: self.tr(state.field.titleKey))
            }
            .toggleStyle(MenuBarRowToggleStyle(verticalPadding: T.space4))
            .accessibilityLabel(self.tr(state.field.titleKey))
            .disabled(self.coreFieldDisabled)

            self.coreFieldStatus(state)
                .padding(.trailing, T.space8)
        }
    }

    func corePortFieldRow(_ state: ConfigOverrideFieldState) -> some View {
        HStack(spacing: T.space6) {
            self.settingsRowLabel(symbol: state.field.symbol, title: self.tr(state.field.titleKey))
                .layoutPriority(1)
            Spacer(minLength: 0)
            TextField(self.tr("ui.placeholder.port"), text: Binding(
                get: {
                    if case let .string(text)? = self.appViewModel.coreSettingsEdits[state.field] { return text }
                    return self.coreSettingText(state.field)
                },
                set: { self.appViewModel.stageCoreSetting(state.field, value: .string($0)) }))
                .textFieldStyle(.roundedBorder)
                .font(.app(size: T.FontSize.body, weight: .regular))
                .foregroundStyle(nativePrimaryLabel)
                .multilineTextAlignment(.trailing)
                .frame(width: self.settingsPortFieldWidth, alignment: .trailing)
                .accessibilityLabel(self.tr(state.field.titleKey))
                .disabled(self.coreFieldDisabled)
            self.coreFieldStatus(state)
        }
        .menuRowPadding(vertical: T.space4)
        .menuBarHover()
    }

    func coreLogLevelRow(_ state: ConfigOverrideFieldState) -> some View {
        let current = self.coreSettingText(.logLevel)
        return self.coreMenuRow(state, valueText: current) { dismiss in
            ForEach(ConfigLogLevel.allCases, id: \.self) { level in
                AttachedPopoverMenuItem(
                    title: level.rawValue,
                    selected: current.caseInsensitiveCompare(level.rawValue) == .orderedSame)
                {
                    self.appViewModel.stageCoreSetting(.logLevel, value: .string(level.rawValue))
                    dismiss()
                }
            }
        }
    }

    func coreMenuRow(
        _ state: ConfigOverrideFieldState, valueText: String,
        @ViewBuilder options: @escaping (_ dismiss: @escaping () -> Void) -> some View
    ) -> some View {
        HStack(spacing: T.space6) {
            self.settingsMenuRow(
                self.tr(state.field.titleKey), symbol: state.field.symbol, valueText: valueText,
                options: options)
                .disabled(self.coreFieldDisabled)
            self.coreFieldStatus(state)
                .padding(.trailing, T.space8)
        }
    }

    func coreSettingText(_ field: ConfigOverrideField) -> String {
        field.valueText(self.appViewModel.coreSettingValue(field), language: self.language) ?? ""
    }

    /// Fixed width so every row's control lands on the same vertical line, whether
    /// or not the field is overridden.
    static let coreStatusColumnWidth: CGFloat = 74

    @ViewBuilder
    func coreFieldStatus(
        _ state: ConfigOverrideFieldState,
        showsFieldName: Bool = false) -> some View
    {
        Group {
            let restoring = self.appViewModel.coreSettingsRestores.contains(state.field.rawValue)
            if restoring || state.isOverridden {
                Button {
                    if restoring {
                        self.appViewModel.undoCoreSettingRestore(state.field)
                    } else {
                        self.appViewModel.stageCoreSettingsRestore([state.field.rawValue])
                    }
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
                .buttonStyle(MenuBarInteractionStyle())
                .foregroundStyle(self.coreStatusTint(state).opacity(T.Opacity.solid))
                .disabled(!self.appViewModel.canRestoreConfigField)
                .help(self.coreRestoreHelp(state, restoring: restoring))
                .accessibilityLabel(self.coreRestoreHelp(state, restoring: restoring))
            } else {
                Text(self.coreStatusChipText(state, showsFieldName: showsFieldName))
                    .font(.app(size: T.FontSize.caption, weight: .regular))
                    .foregroundStyle(self.appViewModel.coreSettingsEdits[state.field] == nil
                        ? self.nativeTertiaryLabel : self.nativeAccent)
                    .lineLimit(1)
            }
        }
        .frame(width: showsFieldName ? nil : Self.coreStatusColumnWidth, alignment: .trailing)
    }

    func coreStatusChipText(_ state: ConfigOverrideFieldState, showsFieldName: Bool) -> String {
        let key = switch (
            self.appViewModel.coreSettingsRestores.contains(state.field.rawValue),
            self.appViewModel.coreSettingsEdits[state.field] != nil, state.isOverridden, state.isUnconfirmed
        ) {
        case (true, _, _, _): "ui.settings.core.restore_pending"
        case (_, true, _, _): "ui.settings.core.edit_pending"
        case (_, _, true, true): "ui.settings.overrides.status.unconfirmed_short"
        case (_, _, true, false): "ui.settings.overrides.status.overridden_short"
        default: "ui.settings.overrides.status.following_short"
        }
        let status = self.tr(key)
        guard showsFieldName else { return status }
        return self.tr("ui.settings.overrides.status.chip_named", self.tr(state.field.titleKey), status)
    }

    func coreRestoreHelp(_ state: ConfigOverrideFieldState, restoring: Bool) -> String {
        let title = self.tr(state.field.titleKey)
        if restoring {
            return self.tr("ui.settings.core.undo_restore", title)
        }
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
        !self.appViewModel.canApplyCoreSettings
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
                .focused(self.$focusedProxyException, equals: exception.id)
                .onSubmit { self.focusedProxyException = nil }

            Button {
                self.appViewModel.removeSystemProxyExceptionDraft(id: exception.id)
                self.appViewModel.saveSystemProxyExceptions()
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
