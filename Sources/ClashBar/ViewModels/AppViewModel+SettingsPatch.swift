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
        isCoreSettingsBatch: Bool = false) async -> Bool
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
        }
        let shouldSyncSystemProxyPort = !self.isRemoteTarget && body.keys.contains { key in
            key == "mixed-port" || key == "port" || key == "socks-port"
        }
        let previousSystemProxyPorts =
            await previousSystemProxyPortsForSyncIfNeeded(shouldSync: shouldSyncSystemProxyPort)

        let patchKeysDescription = body.keys.sorted().joined(separator: ", ")
        var expected = body
        var baseline: ConfigSnapshot?
        var didSendPatch = false
        do {
            if isCoreSettingsBatch {
                baseline = try await self.fetchRuntimeConfigSnapshot()
                let enableKey = ConfigOverrideField.tunEnable.rawValue
                if body[ConfigOverrideField.tunStack.rawValue] != nil, body[enableKey] == nil {
                    expected[enableKey] = baseline?.tunEnabled.map(ConfigPatchValue.bool)
                }
            }
            let request = try await self.coreSettingsPatch(body, baseline: baseline)
            ensureAPIClient()
            appendLog(level: "info", message: "PATCH /configs [\(patchKeysDescription)]")
            didSendPatch = true
            try await self.clientOrThrow().requestNoResponse(.patchConfigs(body: request))
            appendLog(level: "info", message: "PATCH /configs succeeded [\(patchKeysDescription)]")
            let observed = try await self.fetchRuntimeConfigSnapshot()
            guard expected.allSatisfy({ ConfigOverrides.matches($0.value, observed.overrideFields[$0.key]) }) else {
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
            var detail = self.configApplicationErrorMessage(error)
            if didSendPatch, let baseline {
                do {
                    try await self.restoreSettingsPatch(matching: baseline, keys: Set(expected.keys))
                } catch {
                    detail = self.tr("app.config.apply.recovery_failed", detail)
                }
            }
            self.settingsErrorMessage = tr("app.settings.error.save_failed", syncingKey, detail)
            settingsSavedMessage = nil
            await refreshFromAPI(includeSlowCalls: false)
            await self.reconcileEditableSettingsWithRuntimeConfig()
            return false
        }
    }

    private func coreSettingsPatch(
        _ fields: [String: ConfigPatchValue], baseline: ConfigSnapshot?
    ) async throws -> [String: JSONValue] {
        let stack = fields[ConfigOverrideField.tunStack.rawValue]
        let enabled = fields[ConfigOverrideField.tunEnable.rawValue]
        if stack != nil || enabled != nil {
            guard let desired = enabled ?? baseline?.tunEnabled.map(ConfigPatchValue.bool) else {
                throw ConfigApplicationError.unverified
            }
            if desired == .bool(true), !self.isRemoteTarget {
                try await self.ensureTunPermissions(requestIfMissing: true)
            }
        }
        return ConfigOverrides.request(for: fields, tunEnabled: baseline?.tunEnabled).mapValues(\.jsonValue)
    }

    private func restoreSettingsPatch(matching baseline: ConfigSnapshot, keys: Set<String>) async throws {
        let previous = baseline.overrideFields.filter { keys.contains($0.key) }
        let observed = try? await self.fetchRuntimeConfigSnapshot().overrideFields
        let changes = previous.filter { !ConfigOverrides.matches($0.value, observed?[$0.key]) }
        if !changes.isEmpty {
            let body = ConfigOverrides.request(for: changes, tunEnabled: baseline.tunEnabled)
            try await self.clientOrThrow().requestNoResponse(.patchConfigs(body: body.mapValues(\.jsonValue)))
        }
        let restored = try await self.fetchRuntimeConfigSnapshot().overrideFields
        guard previous.count == keys.count,
              previous.allSatisfy({ ConfigOverrides.matches($0.value, restored[$0.key]) })
        else { throw ConfigApplicationError.unverified }
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
