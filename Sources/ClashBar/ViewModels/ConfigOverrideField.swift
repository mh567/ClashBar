import Foundation

/// The section a field is shown under. Mirrors the natural sections of the config
/// file: general switches, the standalone `tun:` block, then the listening ports.
enum ConfigOverrideGroup: String, CaseIterable, Identifiable {
    case general
    case tun
    case ports

    var id: String {
        self.rawValue
    }

    var titleKey: String {
        switch self {
        case .general:
            "ui.settings.group.general"
        case .tun:
            "ui.settings.group.tun"
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

/// How a change to a field takes effect. This is independent of the visible section:
/// a section groups what belongs together, this decides when it is written.
enum CoreApplyMode: Equatable {
    /// Hot-applied through `PATCH /configs`. Safe to send the moment it changes.
    case immediate
    /// One operation touches several fields, so sending each change on its own would
    /// mean several reloads. They collect into a draft and go out as one commit.
    case unifiedCommit
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

    /// Ports share one listening surface and TUN's switch and stack are written as one
    /// object, so either group would reload the core once per field if each change went
    /// out alone. They use the unified commit; everything else is safe to hot-apply.
    var applyMode: CoreApplyMode {
        switch self {
        case .ports, .tun: .unifiedCommit
        case .field: .immediate
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
    case tunEnable = "tun.enable"
    case tunStack = "tun.stack"
    case logLevel = "log-level"
    case mode

    /// Switching the mode from the top bar is a transient runtime choice, so it
    /// must not pin the field. The core settings page no longer offers a mode row,
    /// so a top-bar switch is the only writer.
    static let transientKeys: Set<String> = ["mode"]

    static func isPersistableOnRuntimeChange(_ key: String) -> Bool {
        !self.transientKeys.contains(key)
    }

    var id: String {
        self.rawValue
    }

    /// The section this field is shown under, or `nil` when it has no row of its own.
    /// `mode` is switched from the top bar, so it stays in the model for Restore All
    /// but is never rendered as a core-settings row.
    var group: ConfigOverrideGroup? {
        switch self {
        case .logLevel, .allowLan, .ipv6, .tcpConcurrent:
            .general
        case .tunEnable, .tunStack:
            .tun
        case .port, .socksPort, .mixedPort:
            .ports
        case .mode:
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
        case .port, .socksPort, .mixedPort:
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
        case .tunEnable:
            "ui.quick.tun_mode"
        case .tunStack:
            "ui.settings.tun_stack"
        }
    }

    /// One glyph per concept. `allowLan` used to share `network` with the HTTP port,
    /// which made two unrelated settings look like the same thing.
    var symbol: String {
        switch self {
        case .allowLan:
            "wifi.router"
        case .ipv6:
            "6.circle"
        case .tcpConcurrent:
            "arrow.triangle.branch"
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
        case .tunEnable:
            "lock.shield"
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
