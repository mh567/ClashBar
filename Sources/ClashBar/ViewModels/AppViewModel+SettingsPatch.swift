import Foundation

@MainActor
extension AppViewModel {
    func effectiveMixedPort() -> Int {
        if self.mixedPort > 0 {
            return self.mixedPort
        }

        let trimmed = self.settingsMixedPort.trimmed
        if let value = Int(trimmed), (1...65535).contains(value) {
            return value
        }

        return 7890
    }

    func applyEditableSettingsSnapshotToUI(_ snapshot: EditableSettingsSnapshot) {
        suppressSettingsPersistence = true
        currentMode = snapshot.mode
        settingsAllowLan = snapshot.allowLan
        settingsIPv6 = snapshot.ipv6
        settingsTCPConcurrent = snapshot.tcpConcurrent
        isTunEnabled = snapshot.tunEnabled
        settingsLogLevel = snapshot.logLevel
        settingsPort = snapshot.port
        settingsSocksPort = snapshot.socksPort
        settingsMixedPort = snapshot.mixedPort
        settingsRedirPort = snapshot.redirPort
        settingsTProxyPort = snapshot.tproxyPort
        suppressSettingsPersistence = false
    }

    func applySettingBool(key: String, value: Bool) async {
        await self.patchSingleConfig(key, value: .bool(value))
    }

    func patchSingleConfig(_ key: String, value: ConfigPatchValue) async {
        _ = await self.patchConfigBody(
            [key: value],
            syncingKey: key,
            successMessage: tr("app.settings.saved.single_key", key))
    }

    @discardableResult
    func patchConfigBody(
        _ body: [String: ConfigPatchValue],
        syncingKey: String,
        successMessage: String,
        syncSystemProxyPort: Bool = true) async -> Bool
    {
        guard !self.isConfigMutationBusy, self.isRemoteTarget || self.isRuntimeRunning else { return false }
        let overrideID = self.activeConfigOverrideID
        settingsFeedbackClearTask?.cancel()
        settingsFeedbackClearTask = nil
        self.settingsSyncingKey = syncingKey
        self.configReadEpoch = UUID()
        settingsErrorMessage = nil
        settingsSavedMessage = nil
        defer {
            self.configReadEpoch = UUID()
            settingsSyncingKey = nil
            self.retryPendingProxyPortsAutoSaveIfNeeded()
        }
        let shouldSyncSystemProxyPort = syncSystemProxyPort && !self.isRemoteTarget && body.keys.contains { key in
            key == "mixed-port" || key == "port" || key == "socks-port"
        }
        let previousSystemProxyPorts =
            await previousSystemProxyPortsForSyncIfNeeded(shouldSync: shouldSyncSystemProxyPort)

        let patchKeysDescription = body.keys.sorted().joined(separator: ", ")
        do {
            ensureAPIClient()
            appendLog(level: "info", message: "PATCH /configs [\(patchKeysDescription)]")
            try await self.clientOrThrow().requestNoResponse(.patchConfigs(body: body.mapValues(\.jsonValue)))
            appendLog(level: "info", message: "PATCH /configs succeeded [\(patchKeysDescription)]")
            let observed = try await self.fetchRuntimeConfigSnapshot()
            guard body.allSatisfy({ ConfigOverrides.matches($0.value, observed.overrideFields[$0.key]) }) else {
                throw ConfigApplicationError.unverified
            }
            self.recordConfigOverrides(body, for: overrideID)
            settingsSavedMessage = successMessage
            self.scheduleSettingsFeedbackAutoClearIfNeeded(message: successMessage)
            await self.syncSystemProxyPortIfNeeded(
                shouldSync: shouldSyncSystemProxyPort,
                previousPorts: previousSystemProxyPorts)
            return true
        } catch {
            appendLog(
                level: "error",
                message: "PATCH /configs failed [\(patchKeysDescription)]: \(error.localizedDescription)")
            self.settingsErrorMessage = tr(
                "app.settings.error.save_failed", syncingKey, self.configApplicationErrorMessage(error))
            settingsSavedMessage = nil
            await refreshFromAPI(includeSlowCalls: false)
            await self.reconcileEditableSettingsWithRuntimeConfig()
            return false
        }
    }

    func scheduleSettingsFeedbackAutoClearIfNeeded(message: String) {
        guard message.trimmedNonEmpty != nil else { return }

        settingsFeedbackClearTask?.cancel()
        settingsFeedbackClearTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return
            }

            guard let self else { return }
            if self.settingsSavedMessage == message {
                self.settingsSavedMessage = nil
            }
        }
    }

    func clientOrThrow() throws -> MihomoAPIService {
        if apiClient == nil {
            ensureAPIClient()
        }
        if let apiClient {
            return apiClient
        }
        throw APIError.invalidURL
    }

    private func previousSystemProxyPortsForSyncIfNeeded(shouldSync: Bool) async -> SystemProxyPorts? {
        guard shouldSync, isSystemProxyEnabled else { return nil }
        do {
            let config: ConfigSnapshot = try await self.clientOrThrow().request(.getConfigs)
            return systemProxyPorts(from: config)
        } catch {
            return currentSystemProxyPortsFromState()
        }
    }

    private func syncSystemProxyPortIfNeeded(shouldSync: Bool, previousPorts: SystemProxyPorts?) async {
        guard shouldSync, isSystemProxyEnabled else { return }

        do {
            let target = try await resolveSystemProxyTargetFromRuntimeConfig()
            try await applySystemProxy(enabled: true, host: target.host, ports: target.ports)
            try await self.applyCurrentSystemProxyExceptionsIfNeeded()
            systemProxyActiveDisplay = buildSystemProxyDisplayString(host: target.host, ports: target.ports)
            appendLog(level: "info", message: tr("log.system_proxy.port_synced", target.ports.primaryPort ?? 0))

            if let previousPorts, previousPorts != target.ports {
                await closeAllConnections()
            }
        } catch {
            appendLog(level: "error", message: tr("log.system_proxy.port_sync_failed", systemProxyErrorMessage(error)))
            await self.refreshSystemProxyHelperStatus()
        }
    }

    func applyBooleanSetting(
        _ keyPath: ReferenceWritableKeyPath<AppViewModel, Bool>,
        configKey: String,
        value: Bool) async
    {
        await self.applySettingBool(key: configKey, value: value)
    }

    func reconcileEditableSettingsWithRuntimeConfig() async {
        do {
            let config = try await self.fetchRuntimeConfigSnapshot()
            let incoming = EditableSettingsSnapshot(config: config)
            self.applyEditableSettingsSnapshotToUI(incoming)
            self.lastSyncedEditableSettings = incoming
            self.persistEditableSettingsSnapshot()
        } catch {
            appendLog(level: "error", message: "Settings reconciliation failed: \(error.localizedDescription)")
        }
    }

    var proxyPortFields: [SettingsPortField] {
        [
            SettingsPortField(key: "port", value: settingsPort),
            SettingsPortField(key: "socks-port", value: settingsSocksPort),
            SettingsPortField(key: "mixed-port", value: settingsMixedPort),
            SettingsPortField(key: "redir-port", value: settingsRedirPort),
            SettingsPortField(key: "tproxy-port", value: settingsTProxyPort),
        ]
    }

    func validatedPortPatchBody(
        fields: [SettingsPortField],
        errorMessageKey: String) -> [String: ConfigPatchValue]?
    {
        var body: [String: ConfigPatchValue] = [:]

        for field in fields {
            let trimmedValue = field.value.trimmed
            guard let intValue = Int(trimmedValue), (0...65535).contains(intValue) else {
                settingsErrorMessage = tr(errorMessageKey, field.key)
                settingsSavedMessage = nil
                return nil
            }

            body[field.key] = .int(intValue)
        }

        return body
    }

    func syncEditableFields<Value: Equatable>(
        from previous: EditableSettingsSnapshot,
        to incoming: EditableSettingsSnapshot,
        fields: [(ReferenceWritableKeyPath<AppViewModel, Value>, KeyPath<EditableSettingsSnapshot, Value>)])
    {
        for (stateKeyPath, snapshotKeyPath) in fields {
            guard self[keyPath: stateKeyPath] == previous[keyPath: snapshotKeyPath] else { continue }
            self[keyPath: stateKeyPath] = incoming[keyPath: snapshotKeyPath]
        }
    }
}
