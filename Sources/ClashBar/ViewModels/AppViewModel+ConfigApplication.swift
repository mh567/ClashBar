import CryptoKit
import Foundation

@MainActor
extension AppViewModel {
    var isConfigMutationBusy: Bool {
        self.isCoreActionProcessing || self.runtimeConfigReloadCount > 0
            || self.settingsSyncingKey != nil || self.isTunSyncing || self.isProxySyncing
    }

    /// Drops the loaded-config state. Everything derived from that YAML must be
    /// cleared together, or the UI keeps showing the previous run's values.
    func clearLoadedConfigState() {
        self.runtimeConfigInput = nil
        self.configApplicationLoaded = false
        self.loadedConfigTunRouteExcludeAddress = nil
        self.tunRouteExcludeAddress = nil
    }

    /// True while a pending recovery owns the TUN state, so a core that still
    /// reports its startup default must not overwrite the switch.
    var isAwaitingTunRecovery: Bool {
        self.pendingCoreFeatureRecoveryState?.tunEnabled == true || self.isTunSyncing
    }

    var configApplicationOutcome: ConfigApplicationOutcome {
        guard self.configApplicationLoaded else { return .failed }
        return self.configApplicationFailure == nil && self.configApplicationIssues.isEmpty ? .applied : .partial
    }

    func requireConfigApplied() throws {
        guard self.configApplicationIssues.isEmpty else {
            throw ConfigApplicationError.fields(self.configApplicationIssues)
        }
        guard self.configApplicationOutcome == .applied else { throw ConfigApplicationError.unverified }
    }

    func configApplicationErrorMessage(_ error: Error) -> String {
        switch error as? ConfigApplicationError {
        case .unverified: self.tr("app.config.apply.unverified")
        case let .recoveryFailed(failure): self.tr("app.config.apply.recovery_failed", failure)
        case .stale: self.tr("app.config.apply.stale")
        case let .fields(fields): self.tr("app.config.apply.partial", fields.joined(separator: ", "))
        case nil: self.tunErrorMessage(error)
        }
    }

    func lastLoadedConfigURL(for path: String) -> URL? {
        let url = URL(fileURLWithPath: path)
        let key = ConfigOverrides.pathKey(for: url)
        guard let id = self.configOverrides.identities[key] else { return nil }
        return url.deletingLastPathComponent().appendingPathComponent(".clashbar-loaded-\(id.uuidString).yaml")
    }

    func removeLegacyConfigBackup(for path: String) {
        guard let backup = self.lastLoadedConfigURL(for: path) else { return }
        let target = URL(fileURLWithPath: path)
        guard self.pendingRemoteConfigReplacements[target.lastPathComponent]?.file(beside: target) != backup
        else { return }
        try? FileManager.default.removeItem(at: backup)
    }

    func removeRedundantLegacyConfigBackups() {
        for file in self.configService.availableConfigs {
            guard let backup = self.lastLoadedConfigURL(for: file.path),
                  let data = try? Data(contentsOf: backup),
                  (try? Data(contentsOf: file)) == data
            else { continue }
            self.removeLegacyConfigBackup(for: file.path)
        }
    }

    func acknowledgeLoadedConfig(
        at path: String, yaml: String, status: CoreLifecycleStatus,
        controller: String, overrides: [String: ConfigPatchValue]? = nil
    ) async throws {
        let identity = self.activeConfigOverrideID
        let intended = overrides ?? self.activeConfigOverrides
        let baseline = try await self.fetchRuntimeConfigSnapshot()
        guard self.processManager.status == status, !self.isRemoteTarget, self.activeConfigOverrideID == identity,
              self.configService.selectedConfig.map(ConfigOverrides.pathKey(for:))
                  == ConfigOverrides.pathKey(for: URL(fileURLWithPath: path))
        else { throw ConfigApplicationError.stale }
        let baselineFields = baseline.overrideFields
        let parsed = try ConfigReloadAction.parse(yaml)
        let issues = ConfigReloadAction.baselineListenerIssues(
            declared: parsed.fields, observed: baselineFields, overrides: intended)
        guard issues.isEmpty else { throw ConfigApplicationError.fields(issues) }
        let expected = parsed.fields.merging(intended) { _, override in override }
        self.loadedConfigTunRouteExcludeAddress = parsed.tunRouteExcludeAddress
        let data = Data(yaml.utf8)
        self.runtimeConfigInput = RuntimeConfigInput(
            yaml: yaml, status: status, controller: controller,
            version: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            overrides: intended,
            selectedPath: path)

        var observed: ConfigSnapshot? = baseline
        var failure: String?
        do {
            observed = try await self.applyConfigOverrides(intended, baseline: baseline)
        } catch {
            observed = try? await self.fetchRuntimeConfigSnapshot()
            failure = self.configApplicationErrorMessage(error)
        }

        let fields = observed?.overrideFields ?? [:]
        self.configApplicationIssues = expected.keys.sorted().filter {
            guard let value = expected[$0] else { return false }
            return !ConfigOverrides.matches(value, fields[$0])
        }
        self.configApplicationLoaded = true
        if RuntimeConfigInput.readYAML(at: path) == yaml {
            self.pendingConfigFileNames.remove(URL(fileURLWithPath: path).lastPathComponent)
        }
        self.configApplicationFailure = failure ?? (observed == nil ? self.tr("app.config.apply.unverified") : nil)

        if self.isSystemProxyEnabled {
            do {
                let target = try await self.resolveSystemProxyTargetFromRuntimeConfig()
                if try await !self.isSystemProxyConfigured(host: target.host, ports: target.ports) {
                    try await self.applySystemProxy(enabled: true, host: target.host, ports: target.ports)
                    try await self.applyCurrentSystemProxyExceptionsIfNeeded()
                }
                guard try await self.isSystemProxyConfigured(host: target.host, ports: target.ports) else {
                    throw ConfigApplicationError.unverified
                }
                self.systemProxyActiveDisplay = self.buildSystemProxyDisplayString(
                    host: target.host, ports: target.ports)
            } catch {
                self.configApplicationFailure = self.configApplicationErrorMessage(error)
                self.updateSystemProxyOpenFailureHint(for: error)
            }
        }

        if let failure = self.configApplicationFailure {
            self.appendLog(level: "warning", message: failure)
        }
        if !self.configApplicationIssues.isEmpty {
            let differences = self.configApplicationIssues.joined(separator: ", ")
            self.appendLog(level: "warning", message: self.tr("app.config.apply.partial", differences))
        }
        if self.configApplicationOutcome == .applied, RuntimeConfigInput.readYAML(at: path) == yaml {
            self.removeLegacyConfigBackup(for: path)
        }
        if !intended.isEmpty {
            self.configBaselineFields = baselineFields
        } else {
            self.configBaselineFields = fields
        }
    }

    private func applyConfigOverrides(
        _ fields: [String: ConfigPatchValue], baseline: ConfigSnapshot
    ) async throws -> ConfigSnapshot {
        guard !fields.isEmpty else { return baseline }
        var permitted = fields
        if fields["tun.enable"] == .bool(true), baseline.tunEnabled != true {
            do {
                try await self.ensureTunPermissions(requestIfMissing: false)
            } catch {
                permitted.removeValue(forKey: "tun.enable")
                let body = ConfigOverrides.request(for: permitted, tunEnabled: baseline.tunEnabled)
                if !body.isEmpty {
                    try await self.clientOrThrow().requestNoResponse(.patchConfigs(body: body.mapValues(\.jsonValue)))
                }
                throw error
            }
        }
        let body = ConfigOverrides.request(for: permitted, tunEnabled: baseline.tunEnabled)
        guard !body.isEmpty else { return baseline }
        try await self.clientOrThrow().requestNoResponse(.patchConfigs(body: body.mapValues(\.jsonValue)))
        return try await self.fetchRuntimeConfigSnapshot()
    }

    func loadedConfigFields(for input: RuntimeConfigInput?) async -> [String: ConfigPatchValue]? {
        guard let input, input.status == self.processManager.status else { return nil }
        return try? await self.fetchRuntimeConfigSnapshot().overrideFields
    }

    func requireRestoredConfig(matching expected: [String: ConfigPatchValue]?) async throws {
        guard self.configApplicationLoaded else { throw ConfigApplicationError.unverified }
        guard let expected, !expected.isEmpty else {
            try self.requireConfigApplied()
            return
        }
        let observed = try await self.fetchRuntimeConfigSnapshot().overrideFields
        let mismatches = expected.keys.sorted().filter { key in
            guard let value = expected[key] else { return false }
            return !ConfigOverrides.matches(value, observed[key])
        }
        guard mismatches.isEmpty else { throw ConfigApplicationError.fields(mismatches) }
    }

    func reportRestoredConfig(after failure: String) {
        self.configApplicationFailure = [
            self.tr("app.config.apply.previous_restored"), failure, self.configApplicationFailure,
        ].compactMap { $0 }.joined(separator: " ")
    }

    func restoreLoadedConfig(_ input: RuntimeConfigInput, at path: String, matching fields: [String: ConfigPatchValue]?)
        async throws
    {
        guard let yaml = input.yaml else { throw ConfigApplicationError.unverified }
        try await self.clientOrThrow().requestNoResponse(.putConfigs(force: true, path: path, payload: yaml))
        try await self.acknowledgeLoadedConfig(
            at: path, yaml: yaml, status: input.status, controller: input.controller, overrides: input.overrides)
        try await self.requireRestoredConfig(matching: fields)
    }

    /// Restores every overridden field in a single reload. Restoring one key at a
    /// time would reload the config once per field and interrupt proxying each time.
    func restoreAllConfigFields() async {
        guard !self.isConfigMutationBusy, let id = self.activeConfigOverrideID,
              let input = self.runtimeConfigInput, let yaml = input.yaml,
              let target = self.configService.selectedConfig, let loadedPath = input.selectedPath,
              ConfigOverrides.pathKey(for: target) == ConfigOverrides.pathKey(for: URL(fileURLWithPath: loadedPath)),
              !self.activeConfigOverrides.isEmpty
        else { return }
        let path = target.path
        self.runtimeConfigReloadCount += 1
        self.configReadEpoch = UUID()
        defer {
            self.configReadEpoch = UUID()
            self.runtimeConfigReloadCount -= 1
        }
        let oldFields = await self.loadedConfigFields(for: input)
        do {
            try await self.clientOrThrow().requestNoResponse(.putConfigs(force: true, path: path, payload: yaml))
            try await self.acknowledgeLoadedConfig(
                at: path, yaml: yaml, status: input.status, controller: input.controller, overrides: [:])
            // Only field-level mismatches must keep the overrides. A system proxy
            // reconfiguration failure is unrelated to the user's intent to follow
            // the config file and must not roll the whole restore back.
            guard self.configApplicationIssues.isEmpty else {
                throw ConfigApplicationError.fields(self.configApplicationIssues)
            }
            guard self.configApplicationLoaded else { throw ConfigApplicationError.unverified }
            self.configOverrides.values[id] = nil
            self.runtimeConfigInput?.overrides = [:]
            self.persistConfigOverrides()
        } catch {
            let failure = self.configApplicationErrorMessage(error)
            do {
                try await self.restoreLoadedConfig(input, at: path, matching: oldFields)
                self.reportRestoredConfig(after: failure)
            } catch {
                self.clearLoadedConfigState()
                self.configApplicationFailure = self.tr("app.config.apply.recovery_failed", failure)
            }
            self.settingsErrorMessage = self.tr("app.config.apply.restore_failed", self.configApplicationFailure ?? "")
        }
    }

    func restoreConfigField(_ key: String) async {
        guard !self.isConfigMutationBusy, let id = self.activeConfigOverrideID,
              let input = self.runtimeConfigInput, let yaml = input.yaml,
              let target = self.configService.selectedConfig, let loadedPath = input.selectedPath,
              ConfigOverrides.pathKey(for: target) == ConfigOverrides.pathKey(for: URL(fileURLWithPath: loadedPath)),
              self.configOverrides.values[id]?[key] != nil
        else { return }
        let path = target.path
        var remaining = self.activeConfigOverrides
        remaining.removeValue(forKey: key)
        self.runtimeConfigReloadCount += 1
        self.configReadEpoch = UUID()
        defer {
            self.configReadEpoch = UUID()
            self.runtimeConfigReloadCount -= 1
        }
        let oldFields = await self.loadedConfigFields(for: input)
        do {
            try await self.clientOrThrow().requestNoResponse(.putConfigs(force: true, path: path, payload: yaml))
            try await self.acknowledgeLoadedConfig(
                at: path, yaml: yaml, status: input.status, controller: input.controller, overrides: remaining)
            guard let expected = self.configBaselineFields[key] else { throw ConfigApplicationError.unverified }
            if oldFields?.isEmpty != false { try self.requireConfigApplied() }
            var restoredFields = oldFields ?? [:]
            restoredFields[key] = expected
            try await self.requireRestoredConfig(matching: restoredFields)
            self.configOverrides.values[id] = remaining
            self.runtimeConfigInput?.overrides = remaining
            self.persistConfigOverrides()
        } catch {
            let failure = self.configApplicationErrorMessage(error)
            do {
                try await self.restoreLoadedConfig(input, at: path, matching: oldFields)
                self.reportRestoredConfig(after: failure)
            } catch {
                self.clearLoadedConfigState()
                self.configApplicationFailure = self.tr("app.config.apply.recovery_failed", failure)
            }
            self.settingsErrorMessage = self.tr("app.config.apply.restore_failed", self.configApplicationFailure ?? "")
        }
    }
}
