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
        self.shouldRecoverTunForSelectedConfig || self.isTunSyncing
    }

    var shouldRecoverTunForSelectedConfig: Bool {
        guard !self.isRemoteTarget, let recovery = self.pendingCoreFeatureRecoveryState, recovery.tunEnabled
        else { return false }
        guard let selected = self.configService.selectedConfig else { return recovery.tunConfigID == nil }
        guard let identity = self.configOverrides.identities[ConfigOverrides.pathKey(for: selected)] else {
            return false
        }
        return identity == recovery.tunConfigID
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
        case let .restoreFailed(failure): self.tr("app.config.apply.restore_failed", failure)
        case .systemProxyRequiresPort: self.tr("ui.settings.core.system_proxy_requires_port")
        case let .fields(fields): self.tr("app.config.apply.partial", fields.joined(separator: ", "))
        case nil: error is SystemProxyServiceError ? self.systemProxyErrorMessage(error) : self.tunErrorMessage(error)
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
        controller: String, overrides: [String: ConfigPatchValue]? = nil, requireSystemProxySync: Bool = false
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

        if self.isSystemProxyEnabled || requireSystemProxySync {
            do {
                try await self.synchronizeSystemProxyWithRuntimeConfig()
            } catch {
                self.configApplicationFailure = self.configApplicationErrorMessage(error)
                if requireSystemProxySync { throw error }
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

    func restoreLoadedConfig(
        _ input: RuntimeConfigInput, at path: String, matching fields: [String: ConfigPatchValue]?,
        requireSystemProxySync: Bool = false
    ) async throws
    {
        guard let yaml = input.yaml else { throw ConfigApplicationError.unverified }
        try await self.clientOrThrow().requestNoResponse(.putConfigs(force: true, path: path, payload: yaml))
        try await self.acknowledgeLoadedConfig(
            at: path, yaml: yaml, status: input.status, controller: input.controller, overrides: input.overrides,
            requireSystemProxySync: requireSystemProxySync)
        try await self.requireRestoredConfig(matching: fields)
    }

    var loadedConfigForSettingsRestore: RuntimeConfigInput? {
        guard !self.isRemoteTarget, let input = self.runtimeConfigInput, input.yaml != nil,
              input.status == self.processManager.status,
              let target = self.configService.selectedConfig, let loadedPath = input.selectedPath,
              ConfigOverrides.pathKey(for: target) == ConfigOverrides.pathKey(for: URL(fileURLWithPath: loadedPath))
        else { return nil }
        return input
    }

    func applyCoreSettingsRestores(_ keys: Set<String>, edits: [String: ConfigPatchValue]) async throws {
        guard !self.isConfigMutationBusy, let id = self.activeConfigOverrideID,
              let input = self.loadedConfigForSettingsRestore, let yaml = input.yaml, let path = input.selectedPath
        else { throw ConfigApplicationError.stale }

        let previous = self.activeConfigOverrides
        let previousIssues = Set(self.configApplicationIssues)
        let declared = try ConfigReloadAction.fields(in: yaml)
        let intended = previous.filter { !keys.contains($0.key) }.merging(edits) { _, edit in edit }
        self.runtimeConfigReloadCount += 1
        self.configReadEpoch = UUID()
        defer {
            self.configReadEpoch = UUID()
            self.runtimeConfigReloadCount -= 1
        }

        let baseline = try await self.fetchRuntimeConfigSnapshot()
        let expectedFields = declared.merging(intended) { _, override in override }
        let requireSystemProxySync = try self.isSystemProxyEnabled
            && self.validatedSystemProxyPorts(for: expectedFields) != self.systemProxyPorts(from: baseline)
        // Reloading YAML resets the temporary proxy mode unless it is reapplied with the overrides.
        var runtimeOverrides = intended
        if edits["mode"] == nil, !keys.contains("mode") {
            runtimeOverrides["mode"] = baseline.overrideFields["mode"] ?? intended["mode"]
        }
        let tun = ConfigOverrideField.tunEnable.rawValue
        let desiredTun = intended[tun] ?? declared[tun]
        if desiredTun == .bool(true), edits[tun] != nil || edits[ConfigOverrideField.tunStack.rawValue] != nil {
            try await self.ensureTunPermissions(requestIfMissing: true)
        }

        do {
            try await self.clientOrThrow().requestNoResponse(.putConfigs(force: true, path: path, payload: yaml))
            try await self.acknowledgeLoadedConfig(
                at: path, yaml: yaml, status: input.status, controller: input.controller, overrides: runtimeOverrides,
                requireSystemProxySync: requireSystemProxySync)

            let observed = try await self.fetchRuntimeConfigSnapshot().overrideFields
            var expected = edits
            expected["mode"] = runtimeOverrides["mode"]
            for key in keys {
                expected[key] = declared[key] ?? self.configBaselineFields[key]
            }
            // Previously unapplied overrides may remain unapplied after a reload.
            for (key, value) in previous where intended[key] == value
                && ConfigOverrides.matches(value, baseline.overrideFields[key])
            {
                expected[key] = value
            }
            let mismatches = expected.compactMap { key, value -> String? in
                ConfigOverrides.matches(value, observed[key]) ? nil : key
            }
            let issues = Set(mismatches).union(Set(self.configApplicationIssues).subtracting(previousIssues))
            guard issues.isEmpty else { throw ConfigApplicationError.fields(issues.sorted()) }

            self.configOverrides.values[id] = intended.isEmpty ? nil : intended
            self.runtimeConfigInput?.overrides = intended
            self.persistConfigOverrides()
        } catch {
            let failure = self.configApplicationErrorMessage(error)
            do {
                var recovery = input
                recovery.overrides["mode"] = baseline.overrideFields["mode"]
                try await self.restoreLoadedConfig(
                    recovery, at: path, matching: baseline.overrideFields,
                    requireSystemProxySync: requireSystemProxySync)
                self.runtimeConfigInput?.overrides = input.overrides
                self.reportRestoredConfig(after: failure)
            } catch {
                self.clearLoadedConfigState()
                self.configApplicationFailure = self.tr("app.config.apply.recovery_failed", failure)
            }
            throw ConfigApplicationError.restoreFailed(self.configApplicationFailure ?? failure)
        }
    }
}
