import Foundation

@MainActor
extension AppViewModel {
    enum EditableCoreSetting: String, CaseIterable, Identifiable {
        case allowLan = "allow-lan"
        case ipv6
        case tcpConcurrent = "tcp-concurrent"
        case logLevel = "log-level"

        var id: String {
            self.rawValue
        }

        var configKey: String {
            self.rawValue
        }
    }

    private func boolStateKeyPath(for setting: EditableCoreSetting) -> ReferenceWritableKeyPath<AppViewModel, Bool>? {
        switch setting {
        case .allowLan:
            \.settingsAllowLan
        case .ipv6:
            \.settingsIPv6
        case .tcpConcurrent:
            \.settingsTCPConcurrent
        case .logLevel:
            nil
        }
    }

    private func stringStateKeyPath(for setting: EditableCoreSetting)
    -> ReferenceWritableKeyPath<AppViewModel, String>? {
        switch setting {
        case .logLevel:
            \.settingsLogLevel
        case .allowLan, .ipv6, .tcpConcurrent:
            nil
        }
    }

    func boolValue(for setting: EditableCoreSetting) -> Bool {
        guard let keyPath = self.boolStateKeyPath(for: setting) else {
            assertionFailure("Setting \(setting.configKey) does not store a Bool")
            return false
        }
        return self[keyPath: keyPath]
    }

    func stringValue(for setting: EditableCoreSetting) -> String {
        guard let keyPath = self.stringStateKeyPath(for: setting) else {
            assertionFailure("Setting \(setting.configKey) does not store a String")
            return ""
        }
        return self[keyPath: keyPath]
    }

    func applyEditableCoreSetting(_ setting: EditableCoreSetting, to value: Bool) async {
        guard let keyPath = self.boolStateKeyPath(for: setting) else {
            assertionFailure("Setting \(setting.configKey) does not accept Bool updates")
            return
        }
        await self.applyBooleanSetting(keyPath, configKey: setting.configKey, value: value)
    }

    func applyEditableCoreSetting(_ setting: EditableCoreSetting, to value: String) async {
        guard self.stringStateKeyPath(for: setting) != nil else {
            assertionFailure("Setting \(setting.configKey) does not accept String updates")
            return
        }

        let normalized = value.trimmed
        if setting == .logLevel, ConfigLogLevel(rawValue: normalized) == nil {
            settingsErrorMessage = tr("app.settings.error.invalid_log_level", value)
            settingsSavedMessage = nil
            return
        }

        await self.patchSingleConfig(setting.configKey, value: .string(normalized))
    }

    func applyProxyPorts() async {
        guard !self.editedProxyPorts.isEmpty else { return }
        if self.isConfigMutationBusy {
            self.scheduleProxyPortsAutoSaveIfNeeded()
            return
        }

        let fields = self.proxyPortFields.compactMap { field in
            self.editedProxyPorts[field.key].map { SettingsPortField(key: field.key, value: $0) }
        }
        guard ProxyPortsDraft.isAutoSavable(fields),
              let body = self.validatedPortPatchBody(
                  fields: fields, errorMessageKey: "app.settings.error.port_range")
        else { return }

        for field in fields {
            self.editedProxyPorts.removeValue(forKey: field.key)
        }
        await self.patchConfigBody(
            body, syncingKey: "ports-auto", successMessage: tr("app.settings.saved.ports_auto"))
    }

    func scheduleProxyPortsAutoSaveIfNeeded() {
        guard !suppressSettingsPersistence else { return }
        guard settingsSyncingKey == nil else {
            self.proxyPortsAutoSavePending = true
            return
        }

        self.proxyPortsAutoSavePending = false
        proxyPortsAutoSaveTask?.cancel()
        proxyPortsAutoSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 750_000_000)
            } catch {
                return
            }

            guard let self else { return }
            if Task.isCancelled {
                return
            }
            self.proxyPortsAutoSaveTask = nil
            await self.applyProxyPorts()
        }
    }

    func cancelProxyPortsAutoSave() {
        self.cancelProxyPortsAutoSaveTask()
        self.proxyPortsAutoSavePending = false
    }

    func cancelProxyPortsAutoSaveTask() {
        proxyPortsAutoSaveTask?.cancel()
        proxyPortsAutoSaveTask = nil
    }

    func flushProxyPortsAutoSaveIfNeeded() {
        guard self.proxyPortsAutoSaveTask != nil || self.proxyPortsAutoSavePending else { return }
        self.cancelProxyPortsAutoSave()

        Task { [weak self] in
            guard let self else { return }
            await self.applyProxyPorts()
        }
    }

    func retryPendingProxyPortsAutoSaveIfNeeded() {
        guard self.proxyPortsAutoSavePending else { return }
        guard !self.editedProxyPorts.isEmpty else {
            self.proxyPortsAutoSavePending = false
            return
        }
        self.scheduleProxyPortsAutoSaveIfNeeded()
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
