import Foundation

@MainActor
extension AppViewModel {
    var pendingCoreSettingsCount: Int {
        self.coreSettingsEdits.count + self.coreSettingsRestores.count
    }

    var canApplyCoreSettings: Bool {
        !self.isApplyingCoreSettings && !self.isConfigMutationBusy && (self.isRemoteTarget || self.isRuntimeRunning)
    }

    func coreSettingValue(_ field: ConfigOverrideField) -> ConfigPatchValue? {
        if self.coreSettingsRestores.contains(field.rawValue) {
            return self.configBaselineFields[field.rawValue]
        }
        return self.coreSettingsEdits[field] ?? self.runtimeValue(for: field)
    }

    func stageCoreSetting(_ field: ConfigOverrideField, value: ConfigPatchValue) {
        guard !self.isApplyingCoreSettings else { return }
        self.coreSettingsRestores.remove(field.rawValue)
        let runtime = self.runtimeValue(for: field)
        if field.group == .ports, case let .string(text) = value, case let .string(current)? = runtime {
            let parsed = ProxyPortsDraft.parsedPort(text)
            self.coreSettingsEdits[field] = parsed != nil && parsed == ProxyPortsDraft.parsedPort(current)
                ? nil : value
        } else {
            self.coreSettingsEdits[field] = ConfigOverrides.matches(value, runtime) ? nil : value
        }
        self.coreSettingsError = nil
    }

    func stageCoreSettingsRestore(_ keys: Set<String>) {
        guard self.canRestoreConfigField else { return }
        let overridden = keys.intersection(self.activeConfigOverrides.keys)
        self.coreSettingsRestores.formUnion(overridden)
        self.coreSettingsEdits = self.coreSettingsEdits.filter { !overridden.contains($0.key.rawValue) }
        self.coreSettingsError = nil
    }

    func undoCoreSettingRestore(_ field: ConfigOverrideField) {
        guard !self.isApplyingCoreSettings else { return }
        self.coreSettingsRestores.remove(field.rawValue)
        self.coreSettingsError = nil
    }

    func discardCoreSettings() {
        self.coreSettingsEdits = [:]
        self.coreSettingsRestores = []
        self.coreSettingsError = nil
    }

    func applyCoreSettings() async {
        guard self.pendingCoreSettingsCount > 0, self.canApplyCoreSettings,
              self.coreSettingsRestores.isEmpty || self.canRestoreConfigField
        else { return }

        var values: [String: ConfigPatchValue] = [:]
        for field in ConfigOverrideField.allCases {
            guard let edit = self.coreSettingsEdits[field] else { continue }
            if field.group == .ports {
                guard case let .string(text) = edit, let port = ProxyPortsDraft.parsedPort(text) else {
                    self.coreSettingsError = self.tr("ui.settings.core.invalid_port", self.tr(field.titleKey))
                    return
                }
                values[field.rawValue] = .int(port)
            } else {
                values[field.rawValue] = edit
            }
        }

        if values[ConfigOverrideField.tunStack.rawValue] == .string("mips"), !self.isMipsStackSupported {
            self.coreSettingsError = self.tr("app.tun.mips_requires_upgrade", Self.mipsStackMinimumCoreVersion)
            return
        }
        self.isApplyingCoreSettings = true
        self.coreSettingsError = nil
        self.settingsSavedMessage = nil
        defer { self.isApplyingCoreSettings = false }

        if self.coreSettingsRestores.isEmpty {
            let success = await self.patchConfigBody(
                values, syncingKey: self.tr("ui.settings.section.core"),
                successMessage: self.tr("ui.settings.core.applied"), isCoreSettingsBatch: true)
            guard success else {
                self.coreSettingsError = self.settingsErrorMessage ?? self.tr("app.config.apply.unverified")
                self.settingsErrorMessage = nil
                return
            }
        } else {
            do {
                try await self.applyCoreSettingsRestores(self.coreSettingsRestores, edits: values)
                self.settingsSavedMessage = self.tr("ui.settings.core.applied")
                self.scheduleSettingsFeedbackAutoClearIfNeeded(message: self.tr("ui.settings.core.applied"))
            } catch {
                self.coreSettingsError = self.configApplicationErrorMessage(error)
                return
            }
        }
        self.discardCoreSettings()
    }

    func syncEditableSettings(from config: ConfigSnapshot) {
        let incoming = EditableSettingsSnapshot(config: config)

        guard let previous = lastSyncedEditableSettings else {
            self.applyEditableSettingsSnapshotToUI(incoming)
            lastSyncedEditableSettings = incoming
            persistEditableSettingsSnapshot()
            return
        }

        suppressSettingsPersistence = true
        self.syncEditableFields(
            from: previous,
            to: incoming,
            fields: [
                (\.settingsAllowLan, \.allowLan),
                (\.settingsIPv6, \.ipv6),
                (\.settingsTCPConcurrent, \.tcpConcurrent),
                (\.isTunEnabled, \.tunEnabled),
            ])

        self.syncEditableFields(
            from: previous,
            to: incoming,
            fields: [
                (\.settingsLogLevel, \.logLevel),
                (\.settingsPort, \.port),
                (\.settingsSocksPort, \.socksPort),
                (\.settingsMixedPort, \.mixedPort),
                (\.settingsRedirPort, \.redirPort),
                (\.settingsTProxyPort, \.tproxyPort),
            ])
        suppressSettingsPersistence = false

        lastSyncedEditableSettings = incoming
        persistEditableSettingsSnapshot()
    }

    func currentEditableSettingsSnapshot() -> EditableSettingsSnapshot {
        EditableSettingsSnapshot(
            mode: currentMode,
            allowLan: settingsAllowLan,
            ipv6: settingsIPv6,
            tcpConcurrent: settingsTCPConcurrent,
            tunEnabled: isTunEnabled,
            logLevel: settingsLogLevel,
            port: settingsPort,
            socksPort: settingsSocksPort,
            mixedPort: settingsMixedPort,
            redirPort: settingsRedirPort,
            tproxyPort: settingsTProxyPort)
    }

}
