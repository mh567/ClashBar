import Foundation

enum ConfigOverrideGroup: String, CaseIterable, Identifiable {
    case network
    case ports

    var id: String {
        self.rawValue
    }

    var titleKey: String {
        switch self {
        case .network:
            "ui.settings.group.network"
        case .ports:
            "ui.settings.group.ports"
        }
    }
}

/// A failed apply either has one group's own reason, which is shown verbatim, or
/// several groups' reasons, which need a banner that does not overstate the outcome.
enum CoreSettingsFailure: Equatable {
    case reason(String)
    case grouped(key: String, details: String)
}

enum ConfigOverrideOrigin {
    case explicitSave
    case runtimeAction
}

/// Fields that constrain each other share a submit group so one patch carries the
/// whole constraint. Independent fields get their own group, so a failure in one
/// field never rolls back an unrelated one.
enum ConfigSubmitGroup: Hashable {
    case ports
    case tun
    case field(ConfigOverrideField)

    /// Declaration order of `ConfigOverrideField`, so a single apply issues a
    /// stable sequence of patches.
    static let ordered: [ConfigSubmitGroup] = {
        var groups: [ConfigSubmitGroup] = []
        for field in ConfigOverrideField.allCases where !groups.contains(field.submitGroup) {
            groups.append(field.submitGroup)
        }
        return groups
    }()

    var fields: [ConfigOverrideField] {
        ConfigOverrideField.allCases.filter { $0.submitGroup == self }
    }

    var titleKey: String {
        switch self {
        case .ports:
            "ui.settings.group.ports"
        case .tun:
            "ui.quick.tun_mode"
        case let .field(field):
            field.titleKey
        }
    }
}

enum ConfigOverrideField: String, CaseIterable, Identifiable {
    case allowLan = "allow-lan"
    case ipv6
    case tcpConcurrent = "tcp-concurrent"
    case port
    case socksPort = "socks-port"
    case mixedPort = "mixed-port"
    case redirPort = "redir-port"
    case tproxyPort = "tproxy-port"
    case tunEnable = "tun.enable"
    case tunStack = "tun.stack"
    case logLevel = "log-level"
    case mode

    /// Switching the mode from the top bar is a transient runtime choice, so it
    /// must not pin the field. An explicit change from settings may still do so.
    static let transientKeys: Set<String> = ["mode"]

    static func isPersistableOnRuntimeChange(_ key: String) -> Bool {
        !self.transientKeys.contains(key)
    }

    var id: String {
        self.rawValue
    }

    /// `logLevel` is the most frequently changed field, so it sits at the top of
    /// the core section on its own rather than inside a group.
    var group: ConfigOverrideGroup? {
        switch self {
        case .allowLan, .ipv6, .tcpConcurrent, .tunEnable, .tunStack:
            .network
        case .port, .socksPort, .mixedPort, .redirPort, .tproxyPort:
            .ports
        case .logLevel, .mode:
            nil
        }
    }

    /// TUN enable and stack render as one combined row, so the group card needs to
    /// know to leave them out of the ordinary row loop.
    var isTunSetting: Bool {
        self.submitGroup == .tun
    }

    /// Ports compete for the same listening surface and the system proxy binds to
    /// one of them, so they commit together. TUN enable and stack travel as one
    /// object and share a single permission check. Everything else is independent.
    var submitGroup: ConfigSubmitGroup {
        switch self {
        case .port, .socksPort, .mixedPort, .redirPort, .tproxyPort:
            .ports
        case .tunEnable, .tunStack:
            .tun
        default:
            .field(self)
        }
    }

    var titleKey: String {
        switch self {
        case .allowLan:
            "ui.settings.allow_lan"
        case .ipv6:
            "ui.settings.ipv6"
        case .tcpConcurrent:
            "ui.settings.tcp_concurrent"
        case .logLevel:
            "ui.settings.log_level"
        case .mode:
            "ui.banner.mode.title"
        case .port:
            "ui.settings.port.port"
        case .socksPort:
            "ui.settings.port.socks"
        case .mixedPort:
            "ui.settings.port.mixed"
        case .redirPort:
            "ui.settings.port.redir"
        case .tproxyPort:
            "ui.settings.port.tproxy"
        case .tunEnable:
            "ui.quick.tun_mode"
        case .tunStack:
            "ui.settings.tun_stack"
        }
    }

    var symbol: String {
        switch self {
        case .allowLan:
            "network"
        case .ipv6:
            "globe"
        case .tcpConcurrent:
            "point.3.connected.trianglepath.dotted"
        case .logLevel:
            "text.alignleft"
        case .mode:
            "shield.lefthalf.filled"
        case .port:
            "network"
        case .socksPort:
            "wave.3.right"
        case .mixedPort:
            "arrow.triangle.merge"
        case .redirPort:
            "arrowshape.turn.up.right"
        case .tproxyPort:
            "shield.lefthalf.filled"
        case .tunEnable:
            "network.badge.shield.half.filled"
        case .tunStack:
            "square.3.layers.3d"
        }
    }

    func valueText(_ value: ConfigPatchValue?, language: AppLanguage) -> String? {
        guard let value else { return nil }
        switch value {
        case let .bool(enabled):
            return L10n.t(enabled ? "ui.state.on" : "ui.state.off", language: language)
        case let .int(number):
            return String(number)
        case let .string(text):
            let trimmed = text.trimmed
            guard !trimmed.isEmpty else { return nil }
            return self == .mode ? Self.modeText(trimmed, language: language) : trimmed
        case .object:
            return nil
        }
    }

    static func modeText(_ raw: String, language: AppLanguage) -> String {
        switch raw.lowercased() {
        case "rule":
            L10n.t("ui.mode.rule", language: language)
        case "global":
            L10n.t("ui.mode.global", language: language)
        case "direct":
            L10n.t("ui.mode.direct", language: language)
        default:
            raw
        }
    }
}

struct ConfigOverrideFieldState: Identifiable {
    let field: ConfigOverrideField
    let valueText: String?
    let declaredText: String?
    let isOverridden: Bool
    let isUnconfirmed: Bool

    var id: String {
        self.field.id
    }

    var showsDifference: Bool {
        self.isOverridden && self.declaredText != nil && self.declaredText != self.valueText
    }
}

@MainActor
extension AppViewModel {
    var configOverrideFieldStates: [ConfigOverrideFieldState] {
        let overrides = self.activeConfigOverrides
        let language = self.uiLanguage
        let unconfirmed = Set(self.configApplicationIssues)
        return ConfigOverrideField.allCases.map { field in
            let override = overrides[field.rawValue]
            let declared = self.configBaselineFields[field.rawValue]
            let value = override ?? self.runtimeValue(for: field)
            return ConfigOverrideFieldState(
                field: field,
                valueText: field.valueText(value, language: language),
                declaredText: field.valueText(declared, language: language),
                isOverridden: override != nil,
                isUnconfirmed: unconfirmed.contains(field.rawValue))
        }
    }

    func configOverrideFieldStates(in group: ConfigOverrideGroup) -> [ConfigOverrideFieldState] {
        self.configOverrideFieldStates.filter { $0.field.group == group }
    }

    var ungroupedConfigOverrideFieldStates: [ConfigOverrideFieldState] {
        self.configOverrideFieldStates.filter { $0.field.group == nil }
    }

    /// TUN route exclusions come from the running core, falling back to the value
    /// parsed once when the config was loaded. Never parses YAML here.
    var tunRouteExcludeAddressDisplay: (lines: [String], fromCore: Bool) {
        if let live = self.tunRouteExcludeAddress, !live.isEmpty {
            return (live, true)
        }
        guard let declared = self.loadedConfigTunRouteExcludeAddress, !declared.isEmpty else {
            return ([], false)
        }
        return (declared, false)
    }

    var configOverrideCount: Int {
        self.activeConfigOverrides.count
    }

    var canRestoreConfigField: Bool {
        self.canApplyCoreSettings && self.loadedConfigForSettingsRestore != nil
    }

    func runtimeValue(for field: ConfigOverrideField) -> ConfigPatchValue? {
        switch field {
        case .allowLan:
            .bool(self.settingsAllowLan)
        case .ipv6:
            .bool(self.settingsIPv6)
        case .tcpConcurrent:
            .bool(self.settingsTCPConcurrent)
        case .logLevel:
            .string(self.settingsLogLevel)
        case .mode:
            .string(self.currentMode.rawValue)
        case .port:
            self.portValue(self.settingsPort)
        case .socksPort:
            self.portValue(self.settingsSocksPort)
        case .mixedPort:
            self.portValue(self.settingsMixedPort)
        case .redirPort:
            self.portValue(self.settingsRedirPort)
        case .tproxyPort:
            self.portValue(self.settingsTProxyPort)
        case .tunEnable:
            .bool(self.isTunEnabled)
        case .tunStack:
            self.tunStack.map { .string($0) }
        }
    }

    private func portValue(_ text: String) -> ConfigPatchValue? {
        let trimmed = text.trimmed
        return trimmed.isEmpty ? nil : .string(trimmed)
    }
}
